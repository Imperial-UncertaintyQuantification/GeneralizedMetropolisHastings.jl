type MHRemoteSegments <: AbstractRemoteSegments
    remote::Vector{RemoteRef}
    numproposalspersegment::Int
    numsegments::Int

    prop2collected::Dict{Int,Tuple{Int,Int}}
    collectedsamples::Vector{AbstractSample}
    MHRemoteSegments(r::Vector{RemoteRef},npps::Int,ns::Int) = new(r,npps,ns,Dict{Int,Tuple{Int,Int}}(),Vector{AbstractSample}(ns))
end

@inline _numjobsegments(policy_::MHRuntimePolicy,nproposals::Int) = min(nproposals,_numjobsegments(traittype(policy_.jobsegments)))
@inline _processnumbers(policy_::MHRuntimePolicy,njobsegments::Int) = take(cycle(_processnumbers(traittype(policy_.jobsegments))),njobsegments)

function _remotesegments(policy_::MHRuntimePolicy,model_::AbstractModel,sampler_::AbstractSampler,nproposals::Int)
    njobsegments = _numjobsegments(policy_,nproposals)
    nproposalspersegment = _numproposalspersegment(nproposals,njobsegments)
    procnumbers = collect(_processnumbers(policy_,njobsegments))
    r = RemoteRef[remotecall(i,segment,policy_,model_,sampler_,nproposalspersegment) for i in procnumbers]
    MHRemoteSegments(r,nproposalspersegment,njobsegments)
end

_prop2seg(segments_::MHRemoteSegments,j::Int) = ind2sub((segments_.numproposalspersegment,segments_.numsegments),j)

function _insegmentindex(segments_::MHRemoteSegments,sampleindex_::AbstractVector)
    boolindex_ = [fill(false,segments_.numproposalspersegment) for k=1:segments_.numsegments]
    ntp = numtotalproposals(segments_)
    for i=1:length(sampleindex_)
        @inbounds i1 = sampleindex_[i]-1
        i1==ntp?continue:nothing #if this the final
        si = div(i1,segments_.numproposalspersegment) + 1
        pi = mod(i1,segments_.numproposalspersegment) + 1
        @inbounds boolindex_[si][pi] = true
    end
    map(find,boolindex_)
end

function _insegmentindex2collected!(segments_::MHRemoteSegments,insegmentindex::Array{Array{Int,1},1})
    empty!(segments_.prop2collected)
    d = (segments_.numproposalspersegment,segments_.numsegments)
    for i=1:segments_.numsegments
        for j=1:length(insegmentindex[i])
            segments_.prop2collected[sub2ind(d,insegmentindex[i][j],i)] = (j,i)
        end
    end
    segments_.prop2collected
end

#start the jobs on each process
function iterate!(segments_::MHRemoteSegments,indicatorstate::AbstractSamplerState)
    a = Array{RemoteRef}(segments_.numsegments)
    @sync begin
        for j=1:segments_.numsegments
            a[j] = remotecall(segments_.remote[j].where,iterate!,segments_.remote[j],indicatorstate)
        end
    end #@sync means wait for all processes to finish
    map(fetch,a)
end

#call prepare in order to copy over the new indicator state
function prepare!(segments_::MHRemoteSegments,indicatorstate::AbstractSamplerState,j::Int)
    p,s = _prop2seg(segments_,j)
    r = segments_.remote[s]
    remotecall_fetch(r.where,prepare!,r,indicatorstate,p)
end

function retrievesamples!(segments_::MHRemoteSegments,sampleindex_::AbstractVector)
    insegmentindex = _insegmentindex(segments_,sampleindex_)
    segments_.prop2collected = _insegmentindex2collected!(segments_,insegmentindex)
    @sync begin
        map!((r,i)->(~isempty(i)?remotecall_fetch(r.where,getsamples,r,i):samples(:base,0,0,Float64,Float64)),segments_.collectedsamples,segments_.remote,insegmentindex)
    end
    segments_.collectedsamples
end

function getsamples(segments_::MHRemoteSegments,j::Int)
    if !haskey(segments_.prop2collected,j)
        p,s = _prop2seg(segments_,j)
        r = segments_.remote[s]
        return remotecall_fetch(r.where,getsamples,r,p)
    else
        p,s = segments_.prop2collected[j]
        return copy(segments_.collectedsamples[s],p)
    end
end

function store!(segments_::MHRemoteSegments,chain_::AbstractChain,j::Int)
    p,s = segments_.prop2collected[j]
    store!(chain_,segments_.collectedsamples[s],p)
end

function tune!(segments_::MHRemoteSegments,tvals...)
    @sync begin
        for i=1:segments_.numsegments
            r = segments_.remote[i]
            remotecall_wait(r.where,tune!,r,tvals...)
        end
    end
end

function show(io::IO,r::MHRemoteSegments)
    println(io,"RemoteSegments with $(r.numsegments) segment",r.numsegments==1?"":"s"," and $(r.numproposalspersegment) proposal",r.numproposalspersegment==1?"":"s"," per segment.")
    println(io,"Additional fields: :remote, :collectedsamples, :prop2collected")
    nothing
end

