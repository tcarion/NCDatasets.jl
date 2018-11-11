
function MFDataset(fnames::AbstractArray{TS,N},mode = "r"; aggdim = nothing) where N where TS <: AbstractString
    ds = Dataset.(fnames,mode);

    if aggdim == nothing
        # first unlimited dimensions
        aggdim = NCDatasets.unlimited(ds[1].dim)[1]
    end

    attrib = MFAttributes([d.attrib for d in ds])
    dim = MFDimensions([d.dim for d in ds],aggdim)
    group = MFGroups([d.group for d in ds],aggdim)

    return MFDataset(ds,aggdim,attrib,dim,group)
end

close(mfds::MFDataset) = close.(mfds.ds)

function path(mfds::MFDataset)
    path(mfds.ds[1]) * "…" * path(mfds.ds[end])
end
groupname(mfds::MFDataset) = groupname(mfds.ds[1])
Base.keys(mfds::MFDataset) = keys(mfds.ds[1])

Base.getindex(v::MFVariable,indexes...) = getindex(v.var,indexes...)
Base.setindex!(v::MFVariable,data,indexes...) = setindex!(v.var,data,indexes...)
Base.size(v::MFVariable) = size(v.var)
dimnames(v::MFVariable) = v.dimnames
name(v::MFVariable) = v.varname


function variable(mfds::MFDataset,varname::AbstractString)
    vars = variable.(mfds.ds,varname)

    dim = findfirst(dimnames(vars[1]) .== mfds.aggdim)
    @debug begin
        @show dim
    end

    if (dim != nothing)
        v = CatArrays.CatArray(dim,vars...)
        return MFVariable(v,MFAttributes([var.attrib for var in vars]),
                          dimnames(vars[1]),varname)
    else
        return vars[1]
    end
end


