# The protocol objects: a view of one JSON object, the conversion of a JSON value
# to a Julia value and back, and the helpers that the generated types use.

"""
    ProtocolObject

The supertype of each type of the protocol. A protocol object is a view of one
JSON object, which it holds as a `Dict{String,Any}` of plain JSON values. Its
properties read the fields of that object, with the snake case name of each
field: `request.session_id` reads `"sessionId"`, and `request.meta` reads
`"_meta"`. A field that the type does not name stays in the object, so it
travels on when the object is written again.

`get_json(object)` gives the JSON object. Two protocol objects of the same type
are equal when their JSON objects are equal.
"""
abstract type ProtocolObject end

"""
    get_json(object::ProtocolObject) -> Dict{String,Any}

The JSON object of a protocol object. Do not change it: the object is a view of
it.
"""
get_json(object::ProtocolObject) = getfield(object, :json)

Base.:(==)(a::T, b::T) where {T<:ProtocolObject} = get_json(a) == get_json(b)
Base.hash(object::ProtocolObject, h::UInt) = hash(get_json(object), hash(typeof(object), h))

function Base.show(io::IO, object::ProtocolObject)
    print(io, nameof(typeof(object)), "(")
    JSON.json(io, get_json(object))
    print(io, ")")
end

"""
    convert_from_json(T, value)

Read the plain JSON value `value` as a value of type `T`: a protocol type, a
`String`, an `Int`, a `Float64`, a `Bool`, a `Vector` or a `Dict{String}` of
these, or `Any` for a value that stays as it is. A plain JSON value is a
`Dict{String,Any}`, a `Vector{Any}`, a `String`, a number, a `Bool` or
`nothing`. A value of the wrong shape throws an `ArgumentError`.
"""
function convert_from_json end

convert_from_json(::Type{Any}, value) = value
convert_from_json(::Type{Nothing}, ::Nothing) = nothing
convert_from_json(::Type{String}, value::AbstractString) = String(value)
convert_from_json(::Type{Int}, value::Real) = value isa Bool ? _throw_shape_error(Int, value) : Int(value)
convert_from_json(::Type{Float64}, value::Real) =
    value isa Bool ? _throw_shape_error(Float64, value) : Float64(value)
convert_from_json(::Type{Bool}, value::Bool) = value
convert_from_json(::Type{Dict{String,Any}}, value::AbstractDict) = _make_plain(value)
convert_from_json(::Type{T}, value::AbstractDict) where {T<:ProtocolObject} =
    isabstracttype(T) ? _throw_shape_error(T, value) : T(_make_plain(value))
convert_from_json(::Type{Vector{T}}, value::AbstractVector) where {T} =
    T[convert_from_json(T, item) for item in value]
convert_from_json(::Type{Dict{String,T}}, value::AbstractDict) where {T} =
    Dict{String,T}(String(key) => convert_from_json(T, item) for (key, item) in value)
convert_from_json(::Type{Union{Nothing,T}}, value) where {T} =
    value === nothing ? nothing : convert_from_json(T, value)
convert_from_json(::Type{T}, value) where {T} =
    T isa Union && value isa T ? value : _throw_shape_error(T, value)

_throw_shape_error(type, value) =
    throw(ArgumentError("A JSON $(_get_shape_name(value)) can not be read as a `$(type)`."))

_get_shape_name(::AbstractDict) = "object"
_get_shape_name(::AbstractVector) = "array"
_get_shape_name(::AbstractString) = "string"
_get_shape_name(::Bool) = "boolean"
_get_shape_name(::Real) = "number"
_get_shape_name(::Nothing) = "null"
_get_shape_name(value) = "value of the type `$(typeof(value))`"

"""
    convert_to_json(value)

The plain JSON value of `value`: the JSON object of a protocol object, and the
same for each item of a vector and each value of a dictionary. A string, a
number, a `Bool` and `nothing` stay as they are, and a `Symbol` becomes a
string.
"""
convert_to_json(value::ProtocolObject) = get_json(value)
convert_to_json(value::AbstractString) = String(value)
convert_to_json(value::Symbol) = String(value)
convert_to_json(value::Union{Nothing,Bool,Integer,AbstractFloat}) = value
convert_to_json(value::AbstractVector) = Any[convert_to_json(item) for item in value]
convert_to_json(value::Tuple) = Any[convert_to_json(item) for item in value]
convert_to_json(value::AbstractDict) =
    Dict{String,Any}(String(key) => convert_to_json(item) for (key, item) in value)
convert_to_json(value) =
    throw(ArgumentError("A value of the type `$(typeof(value))` has no JSON form."))

# A protocol object holds plain values: a `Dict{String,Any}`, a `Vector{Any}`, a
# `String`, a number, a `Bool` or `nothing`. A dictionary with other keys or
# values becomes one.
_make_plain(value::AbstractDict) =
    Dict{String,Any}(String(key) => _make_plain(item) for (key, item) in pairs(value))
_make_plain(value::AbstractVector) = Any[_make_plain(item) for item in value]
_make_plain(value::AbstractString) = String(value)
_make_plain(value) = value

"""
    read_json(text::AbstractString) -> plain JSON value
    read_json(T, text::AbstractString)

Parse the JSON text into a plain JSON value, or into a value of type `T` with
`convert_from_json`.
"""
read_json(text::AbstractString) = JSON.parse(text; dicttype = Dict{String,Any})
read_json(::Type{T}, text::AbstractString) where {T} = convert_from_json(T, read_json(text))

"""
    write_json(value) -> String

The JSON text of `value`, on one line.
"""
write_json(value) = JSON.json(convert_to_json(value))

"""
    get_method_name(T::Type) -> String

The name of the method whose request or notification has the type `T`, such as
`"session/prompt"` for `PromptRequest`.
"""
function get_method_name end

"""
    get_response_type(T::Type) -> Type

The type of the answer of the request type `T`, such as `PromptResponse` for
`PromptRequest`.
"""
function get_response_type end

# The helpers of the generated types.

function _read_required(::Type{T}, json::Dict{String,Any}, key::String, owner::Type) where {T}
    haskey(json, key) || throw(ArgumentError("The field `$(key)` of a `$(nameof(owner))` is missing."))
    convert_from_json(T, json[key])
end

function _read_optional(::Type{T}, json::Dict{String,Any}, key::String) where {T}
    value = get(json, key, nothing)
    value === nothing ? nothing : convert_from_json(T, value)
end

# The keys of the required fields of a type.
_get_required_keys(::Type) = ()

# A view reads a field only when it is used. The parameters of a message are
# checked when they come, so a message without a required field gets an answer
# that says so.
function _check_required_fields(object::ProtocolObject)
    json = get_json(object)
    for key in _get_required_keys(typeof(object))
        haskey(json, key) ||
            throw(ArgumentError("The field `$(key)` of a `$(nameof(typeof(object)))` is missing."))
    end
    object
end

# `_meta` that is not an object counts as absent.
function _read_meta(json::Dict{String,Any})
    value = get(json, "_meta", nothing)
    value isa AbstractDict ? _make_plain(value) : nothing
end

function _write_optional!(json::Dict{String,Any}, key::String, ::Type{T}, value) where {T}
    value === nothing || (json[key] = _convert_member_to_json(T, value))
    nothing
end

# The plain JSON value of `value` in a field of the type `T`. A variant of a
# tagged union gets its tag when `T` is the union, because the type of a variant
# can also be the type of a field that is no union, where it has no tag.
_convert_member_to_json(::Type{T}, value) where {T} = convert_to_json(value)
_convert_member_to_json(::Type{Any}, value) = convert_to_json(value)
_convert_member_to_json(::Type{Union{Nothing,T}}, value) where {T} =
    value === nothing ? nothing : _convert_member_to_json(T, value)
_convert_member_to_json(::Type{Vector{T}}, value::AbstractVector) where {T} =
    Any[_convert_member_to_json(T, item) for item in value]
_convert_member_to_json(::Type{Dict{String,T}}, value::AbstractDict) where {T} =
    Dict{String,Any}(String(key) => _convert_member_to_json(T, item) for (key, item) in value)
function _convert_member_to_json(::Type{T}, value::ProtocolObject) where {T<:ProtocolObject}
    json = get_json(value)
    tag = _find_variant_tag(T, typeof(value))
    (tag === nothing || haskey(json, first(tag))) && return json
    tagged = copy(json)
    tagged[first(tag)] = last(tag)
    tagged
end

# The tag of the variant `V` in the union `U`, as `key => value`, or `nothing`.
_find_variant_tag(::Type, ::Type) = nothing

# The variant of a union that its tag names, or `default` when the object has no
# tag, or `other` for a tag that the schema does not name.
function _read_tagged(variants::Dict{String,DataType}, default::Union{Nothing,DataType},
                      other::DataType, key::String, value::AbstractDict)
    json = _make_plain(value)
    tag = get(json, key, nothing)
    type = tag === nothing ? something(default, other) : get(variants, tag, other)
    type(json)
end

# Whether a plain JSON value has the kind that a schema names.
_is_json_kind(value, kind::String) =
    kind == "null"    ? value === nothing :
    kind == "boolean" ? value isa Bool :
    kind == "integer" ? value isa Integer && !(value isa Bool) :
    kind == "number"  ? value isa Real && !(value isa Bool) :
    kind == "string"  ? value isa AbstractString :
    kind == "array"   ? value isa AbstractVector :
    kind == "object"  ? value isa AbstractDict : false

# Whether the first item of an array has all `keys`. An empty array has.
_has_first_item_keys(value::AbstractVector, keys) =
    isempty(value) || (first(value) isa AbstractDict && all(key -> haskey(first(value), key), keys))

# The first variant of a union whose required fields are all in the object, or
# `other`.
function _read_structural(variants::Vector{Pair{DataType,Vector{String}}}, other::DataType,
                          value::AbstractDict)
    json = _make_plain(value)
    for (type, keys) in variants
        all(key -> haskey(json, key), keys) && return type(json)
    end
    other(json)
end
