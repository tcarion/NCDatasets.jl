#=
Functionality and definitions
related with the `Variables` types/subtypes
=#



############################################################
# Helper functions (internal)
############################################################
"Return all variable names"
listVar(ncid) = String[nc_inq_varname(ncid,varid)
                       for varid in nc_inq_varids(ncid)]


"""
    ds = dataset(var::Union{Variable,CFVariable})
    ds = NCDataset(var::Union{Variable,CFVariable})

Return the `NCDataset` containing the variable `var`.
"""
dataset(var::Variable) = var.ds

# old function call, replace by CommonDataModel.dataset
NCDataset(v::Union{AbstractNCVariable,CFVariable}) = dataset(v)

"""
    sz = size(var::Variable)

Return a tuple of integers with the size of the variable `var`.

!!! note

    Note that the size of a variable can change, i.e. for a variable with an
    unlimited dimension.
"""
Base.size(v::Variable{T,N}) where {T,N} = ntuple(i -> nc_inq_dimlen(v.ds.ncid,v.dimids[i]),Val(N))



"""
    renameVar(ds::NCDataset,oldname,newname)

Rename the variable called `oldname` to `newname`.
"""
function renameVar(ds::NCDataset,oldname::AbstractString,newname::AbstractString)
    # make sure that the file is in define mode
    defmode(ds)
    varid = nc_inq_varid(ds.ncid,oldname)
    nc_rename_var(ds.ncid,varid,newname)
    return nothing
end
export renameVar


############################################################
# Obtaining variables
############################################################

function variable(ds::NCDataset,varid::Integer)
    dimids = nc_inq_vardimid(ds.ncid,varid)
    nctype = _jltype(ds.ncid,nc_inq_vartype(ds.ncid,varid))
    ndims = length(dimids)
    attrib = Attributes(ds,varid)

    # reverse dimids to have the dimension order in Fortran style
    return Variable{nctype,ndims,typeof(ds)}(ds,varid, (reverse(dimids)...,), attrib)
end


function _variable(ds::NCDataset,varname)
    varid = nc_inq_varid(ds.ncid,varname)
    return variable(ds,varid)
end

"""
    v = variable(ds::NCDataset,varname::String)

Return the NetCDF variable `varname` in the dataset `ds` as a
`NCDataset.Variable`. No scaling or other transformations are applied when the
variable `v` is indexed.
"""
variable(ds::NCDataset,varname::AbstractString) = _variable(ds,varname)
variable(ds::NCDataset,varname::Symbol) = _variable(ds,varname)

export variable


function checkbuffer(len,data)
    if length(data) != len
        throw(DimensionMismatch("expected an array with $(len) elements, but got an arrow with $(length(data)) elements"))
    end
end

@inline function unsafe_load!(ncvar::Variable, data, indices::Union{Integer, UnitRange, StepRange, Colon}...)
    sizes = size(ncvar)
    normalizedindices = normalizeindexes(sizes, indices)
    ind = to_indices(ncvar,normalizedindices)

    start,count,stride,jlshape = ncsub(ind)

    @boundscheck begin
        checkbounds(ncvar,indices...)
        checkbuffer(prod(count),data)
    end

    nc_get_vars!(ncvar.ds.ncid,ncvar.varid,start,count,stride,data)
end

"""
    NCDatasets.load!(ncvar::Variable, data, indices)

Loads a NetCDF variables `ncvar` in-place and puts the result in `data` along the
specified `indices`. One can use @inbounds annotate code where
bounds checking can be elided by the compiler (which typically require
type-stable code).

```julia
using NCDatasets
ds = NCDataset("file.nc")
ncv = ds["vgos"].var;
# data must have the right shape and type
data = zeros(eltype(ncv),size(ncv));
NCDatasets.load!(ncv,data,:,:,:)
# or
# @inbounds NCDatasets.load!(ncv,data,:,:,:)
close(ds)

# loading a subset
data = zeros(5); # must have the right shape and type
load!(ds["temp"].var,data,:,1) # loads the 1st column
```

!!! note

    For a netCDF variable of type `NC_CHAR`, the element type of the `data`
    array must be `UInt8` and cannot be the julia `Char` type, because the
    julia `Char` type uses 4 bytes and the NetCDF `NC_CHAR` only 1 byte.
"""
@inline function load!(ncvar::Variable{T,N}, data::AbstractArray{T}, indices::Union{Integer, UnitRange, StepRange, Colon}...) where {T,N}
    unsafe_load!(ncvar, data, indices...)
end

@inline function load!(ncvar::Variable{Char,N}, data::AbstractArray{UInt8}, indices::Union{Integer, UnitRange, StepRange, Colon}...) where N
    unsafe_load!(ncvar, data, indices...)
end

@inline function load!(ncvar::Variable{T,2}, data::AbstractArray{T}, i::Colon,j::UnitRange) where T
    # reversed and 0-based
    start = [first(j)-1,0]
    count = [length(j),size(ncvar,1)]

    @boundscheck begin
        checkbounds(ncvar,i,j)
        checkbuffer(prod(count),data)
    end

    nc_get_vara!(ncvar.ds.ncid,ncvar.varid,start,count,data)
end


"""
     data = loadragged(ncvar,index::Union{Colon,UnitRange,Int})

Load data from `ncvar` in the [contiguous ragged array representation](https://web.archive.org/web/20190111092546/http://cfconventions.org/cf-conventions/v1.6.0/cf-conventions.html#_contiguous_ragged_array_representation) as a
vector of vectors. It is typically used to load a list of profiles
or time series of different length each.

The [indexed ragged array representation](https://web.archive.org/web/20190111092546/http://cfconventions.org/cf-conventions/v1.6.0/cf-conventions.html#_indexed_ragged_array_representation) is currently not supported.
"""
function loadragged(ncvar,index::Union{Colon,UnitRange})
    ds = dataset(ncvar)

    dimensionnames = dimnames(ncvar)
    if length(dimensionnames) !== 1
        throw(NetCDFError(-1, "NetCDF variable $(name(ncvar)) should have only one dimensions"))
    end
    dimname = dimensionnames[1]

    ncvarsizes = varbyattrib(ds,sample_dimension = dimname)
    if length(ncvarsizes) !== 1
        throw(NetCDFError(-1, "There should be exactly one NetCDF variable with the attribute 'sample_dimension' equal to '$(dimname)'"))
    end

    # ignore _FillValue which can be 0 for WOD
    ncvarsize = ncvarsizes[1].var

    isa(index,Colon)||(index[1]==1) ? n0=1 : n0=1+sum(ncvarsize[1:index[1]-1])
    isa(index,Colon) ? n1=sum(ncvarsize[:]) : n1=sum(ncvarsize[1:index[end]])

    varsize = ncvarsize[index]

    istart = 0;
    tmp = ncvar[n0:n1]

    T = typeof(view(tmp,1:varsize[1]))
    data = Vector{T}(undef,length(varsize))

    for i in eachindex(varsize,data)
        data[i] = view(tmp,istart+1:istart+varsize[i]);
        istart += varsize[i]
    end
    return data
end

loadragged(ncvar,index::Int) = loadragged(ncvar,index:index)

export loadragged



############################################################
# User API regarding Variables
############################################################
"""
    dimnames(v::Variable)

Return a tuple of strings with the dimension names of the variable `v`.
"""
function dimnames(v::Variable{T,N}) where {T,N}
    return ntuple(i -> nc_inq_dimname(v.ds.ncid,v.dimids[i]),Val(N))
end
export dimnames


function dim(v::AbstractNCVariable,dimname::AbstractString)
    if !(dimname in dimnames(v))
        error("$dimname is not among the dimensions of $(name(v))")
    end
    return dim(dataset(v),dimname)
end

"""
    name(v::Variable)

Return the name of the NetCDF variable `v`.
"""
name(v::Variable) = nc_inq_varname(v.ds.ncid,v.varid)
export name

chunking(v::Variable,storage,chunksizes) = nc_def_var_chunking(v.ds.ncid,v.varid,storage,reverse(chunksizes))

"""
    storage,chunksizes = chunking(v::Variable)

Return the storage type (`:contiguous` or `:chunked`) and the chunk sizes
of the varable `v`.
"""
function chunking(v::Variable)
    storage,chunksizes = nc_inq_var_chunking(v.ds.ncid,v.varid)
    return storage,reverse(chunksizes)
end
export chunking

"""
    isshuffled,isdeflated,deflate_level = deflate(v::Variable)

Return compression information of the variable `v`. If shuffle
is `true`, then shuffling (byte interlacing) is activated. If
deflate is `true`, then the data chunks (see `chunking`) are
compressed using the compression level `deflate_level`
(0 means no compression and 9 means maximum compression).
"""
deflate(v::Variable,shuffle,deflate,deflate_level) = nc_def_var_deflate(v.ds.ncid,v.varid,shuffle,deflate,deflate_level)
deflate(v::Variable) = nc_inq_var_deflate(v.ds.ncid,v.varid)
export deflate

checksum(v::Variable,checksummethod) = nc_def_var_fletcher32(v.ds.ncid,v.varid,checksummethod)

"""
    checksummethod = checksum(v::Variable)

Return the checksum method of the variable `v` which can be either
be `:fletcher32` or `:nochecksum`.
"""
checksum(v::Variable) = nc_inq_var_fletcher32(v.ds.ncid,v.varid)
export checksum

function fillmode(v::Variable)
    no_fill,fv = nc_inq_var_fill(v.ds.ncid, v.varid)
    return no_fill,fv
end
export fillmode

"""
    fv = fillvalue(v::Variable)
    fv = fillvalue(v::CFVariable)

Return the fill-value of the variable `v`.
"""
function fillvalue(v::Variable{NetCDFType,N}) where {NetCDFType,N}
    no_fill,fv = nc_inq_var_fill(v.ds.ncid, v.varid)
    return fv::NetCDFType
end
export fillvalue


"""
    a = nomissing(da)

Return the values of the array `da` of type `Array{Union{T,Missing},N}`
(potentially containing missing values) as a regular Julia array `a` of the same
element type. It raises an error if the array contains at least one missing value.

"""
function nomissing(da::AbstractArray{Union{T,Missing},N}) where {T,N}
    if any(ismissing, da)
        error("arrays contains missing values (values equal to the fill values attribute in the NetCDF file)")
    end
    if VERSION >= v"1.2"
        # Illegal instruction (core dumped) in Julia 1.0.5
        # but works on Julia 1.2
        return Array{T,N}(da)
    else
        # old
        if isempty(da)
            return Array{T,N}([])
        else
            return replace(da, missing => da[1])
        end
    end
end

nomissing(a::AbstractArray) = a

"""
    a = nomissing(da,value)

Retun the values of the array `da` of type `AbstractArray{Union{T,Missing},N}`
as a regular Julia array `a` by replacing all missing value by `value`
(converted to type `T`).
This function is identical to `coalesce.(da,T(value))` where T is the element
type of `da`.
## Example:

```julia-repl
julia> nomissing([missing,1.,2.],NaN)
# returns [NaN, 1.0, 2.0]
```
"""
function nomissing(da::AbstractArray{Union{T,Missing},N},value) where {T,N}
    return replace(da, missing => T(value))
end

nomissing(a::AbstractArray,value) = a
export nomissing

# This method needs to be duplicated instead of using an Union. Otherwise a DiskArrays fallback is called instead which impacts performances
# (see https://github.com/Alexander-Barth/NCDatasets.jl/pull/205#issuecomment-1589575041)
function readblock!(v::Variable, aout, indexes::TI...) where TI <: Union{AbstractUnitRange,StepRange}
    datamode(v.ds)
    _readblock!(v, aout, indexes...)
    return aout
end

_readblock!(v::Variable, aout, indexes::AbstractUnitRange...) = _read_data_from_nc!(v, aout, indexes...)
_readblock!(v::Variable, aout, indexes::StepRange...) = _read_data_from_nc!(v, aout, indexes...)

readblock!(v::Variable, aout) = _read_data_from_nc!(v::Variable, aout)

function _read_data_from_nc!(v::Variable, aout, indexes::Int...)
    aout .= nc_get_var1(eltype(v),v.ds.ncid,v.varid,[i-1 for i in reverse(indexes)])
end

function _read_data_from_nc!(v::Variable{T,N}, aout, indexes::TR...) where {T,N} where TR <: Union{StepRange{Int,Int},UnitRange{Int}}
    start,count,stride,jlshape = ncsub(indexes)
    nc_get_vars!(v.ds.ncid,v.varid,start,count,stride,aout)
end

function _read_data_from_nc!(v::Variable{T,N}, aout, indexes::Union{Int,Colon,AbstractRange{<:Integer}}...) where {T,N}
    sz = size(v)
    start,count,stride = ncsub2(sz,indexes...)
    jlshape = _shape_after_slice(sz,indexes...)
    nc_get_vars!(v.ds.ncid,v.varid,start,count,stride,aout)
end

_read_data_from_nc!(v::Variable, aout) = _read_data_from_nc!(v, aout, 1)

function writeblock!(v::Variable, data, indexes::TI...) where TI <: Union{AbstractUnitRange,StepRange}
    datamode(v.ds)
    _write_data_to_nc(v, data, indexes...)
    return data
end

function _write_data_to_nc(v::Variable{T,N},data,indexes::Int...) where {T,N}
    nc_put_var1(v.ds.ncid,v.varid,[i-1 for i in reverse(indexes)],T(data[1]))
end

_write_data_to_nc(v::Variable, data) = _write_data_to_nc(v, data, 1)

function _write_data_to_nc(v::Variable{T, N}, data, indexes::StepRange{Int,Int}...) where {T, N}
    start,count,stride,jlshape = ncsub(indexes)
    nc_put_vars(v.ds.ncid,v.varid,start,count,stride,T.(data))
end

function _write_data_to_nc(v::Variable, data, indexes::Union{AbstractRange{<:Integer}}...)
    ind = prod(length.(indexes)) == 1 ? first.(indexes) : normalizeindexes(size(v),indexes)
    return _write_data_to_nc(v, data, ind...)
end

getchunksize(v::Variable) = getchunksize(haschunks(v),v)
getchunksize(::DiskArrays.Chunked, v::Variable) = Tuple(chunking(v)[2])
# getchunksize(::DiskArrays.Unchunked, v::Variable) = DiskArrays.estimate_chunksize(v)
getchunksize(::DiskArrays.Unchunked, v::Variable) = size(v)
eachchunk(v::CFVariable) = eachchunk(v.var)
haschunks(v::CFVariable) = haschunks(v.var)
eachchunk(v::Variable) = DiskArrays.GridChunks(v, Tuple(getchunksize(v)))
haschunks(v::Variable) = (chunking(v)[1] == :contiguous ? DiskArrays.Unchunked() : DiskArrays.Chunked())

_normalizeindex(n,ind::Base.OneTo) = 1:1:ind.stop
_normalizeindex(n,ind::Colon) = 1:1:n
_normalizeindex(n,ind::Int) = ind:1:ind
_normalizeindex(n,ind::UnitRange) = StepRange(ind)
_normalizeindex(n,ind::StepRange) = ind
_normalizeindex(n,ind) = error("unsupported index")

# indexes can be longer than sz
function normalizeindexes(sz,indexes)
    return ntuple(i -> _normalizeindex(sz[i],indexes[i]), length(sz))
end


# computes the shape of the array of size `sz` after applying the indexes
# size(a[indexes...]) == _shape_after_slice(size(a),indexes...)

# the difficulty here is to make the size inferrable by the compiler
@inline _shape_after_slice(sz,indexes...) = __sh(sz,(),1,indexes...)
@inline __sh(sz,sh,n,i::Integer,indexes...) = __sh(sz,sh,               n+1,indexes...)
@inline __sh(sz,sh,n,i::Colon,  indexes...) = __sh(sz,(sh...,sz[n]),    n+1,indexes...)
@inline __sh(sz,sh,n,i,         indexes...) = __sh(sz,(sh...,length(i)),n+1,indexes...)
@inline __sh(sz,sh,n) = sh


function ncsub(indexes::NTuple{N,T}) where N where T
    rindexes = reverse(indexes)
    count  = Int[length(i)  for i in rindexes]
    start  = Int[first(i)-1 for i in rindexes]     # use zero-based indexes
    stride = Int[step(i)    for i in rindexes]
    jlshape = length.(indexes)::NTuple{N,Int}
    return start,count,stride,jlshape
end

@inline start_count_stride(n,ind::AbstractRange) = (first(ind)-1,length(ind),step(ind))
@inline start_count_stride(n,ind::Integer) = (ind-1,1,1)
@inline start_count_stride(n,ind::Colon) = (0,n,1)

@inline function ncsub2(sz,indexes...)
    N = length(sz)

    start = Vector{Int}(undef,N)
    count = Vector{Int}(undef,N)
    stride = Vector{Int}(undef,N)

    for i = 1:N
        ind = indexes[i]
        ri = N-i+1
        @inbounds start[ri],count[ri],stride[ri] = start_count_stride(sz[i],ind)
    end

    return start,count,stride
end

Base.getindex(v::Union{MFVariable,DeferVariable},ci::CartesianIndices) = v[ci.indices...]
Base.setindex!(v::Union{MFVariable,DeferVariable},data,ci::CartesianIndices) = setindex!(v,data,ci.indices...)
