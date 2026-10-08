# Generate src/types.jl from schema/schema.json: one Julia type for each
# definition of the schema of the Agent Client Protocol.
#
#     julia --project=. gen/generate.jl
#
# Each definition has one of these forms:
#
# - an object                 a view type with a property for each field
# - a tagged union            an abstract type, a view type for each variant that
#                             a tag names, and `Other<Union>` for a tag that the
#                             schema does not name; the tag picks the variant
# - a structural union        the same, but the required fields pick the variant
# - a flat union              one view type with the fields of all alternatives,
#                             for alternatives that only add optional fields
# - a primitive union         a `Union` of plain types, picked by the JSON kind
# - an enum                   an alias of `String` or `Int`, with its values in
#                             the documentation
# - an alias                  an alias of `String`, `Int`, `Float64` or `Bool`
#
# A variant reuses the type of the definition that it references when only this
# variant references it as a variant. Else it gets a type of its own,
# `<Union><Tag>`, or a name from `VARIANT_NAMES`.

using JSON

const ROOT = dirname(@__DIR__)
const SCHEMA_PATH = joinpath(ROOT, "schema", "schema.json")
const TYPES_PATH = joinpath(ROOT, "src", "types.jl")

# The release of the schema in schema/schema.json. Change it with the schema.
const SCHEMA_RELEASE = "1.7.0"

# The names of the variant types that the rule `<Union><Tag>` makes too long.
const VARIANT_NAMES = Dict(
    ("SessionUpdate", "user_message_chunk") => "UserMessageChunk",
    ("SessionUpdate", "agent_message_chunk") => "AgentMessageChunk",
    ("SessionUpdate", "agent_thought_chunk") => "AgentThoughtChunk")

# The Julia keywords that a field name can be. Such a field gets `_` at its end.
const JULIA_KEYWORDS = Set(["baremodule", "begin", "break", "catch", "const", "continue", "do",
    "else", "elseif", "end", "export", "false", "finally", "for", "function", "global", "if",
    "import", "let", "local", "macro", "module", "quote", "return", "struct", "true", "try",
    "using", "while", "abstract", "mutable", "primitive", "where", "in", "isa", "outer", "public"])

# A `Dict` loses the order of its keys, so the order of the keys of each object
# of the schema is kept here, and the fields of a type follow it.
const KEY_ORDERS = IdDict{Any,Vector{String}}()

function make_plain(value::AbstractDict)
    plain = Dict{String,Any}(String(key) => make_plain(item) for (key, item) in pairs(value))
    KEY_ORDERS[plain] = [String(key) for key in keys(value)]
    plain
end

get_ordered_pairs(dict) = [key => dict[key] for key in get(() -> sort!(collect(keys(dict))), KEY_ORDERS, dict)
                           if haskey(dict, key)]

function filter_ordered(predicate, dict)
    filtered = filter(predicate, dict)
    KEY_ORDERS[filtered] = [first(pair) for pair in get_ordered_pairs(dict) if predicate(pair)]
    filtered
end
make_plain(value::AbstractVector) = Any[make_plain(item) for item in value]
make_plain(value::AbstractString) = String(value)
make_plain(value) = value

# JSON.jl reads an object as an ordered `JSON.Object`.
const SCHEMA = JSON.parse(read(SCHEMA_PATH, String))
const DEFINITION_NAMES = String[String(key) for key in keys(SCHEMA["\$defs"])]
const DEFINITIONS = make_plain(SCHEMA["\$defs"])

# --- The form of each definition ---------------------------------------------

get_alternatives(schema) = get(schema, "anyOf", get(schema, "oneOf", nothing))

# The definition that a schema references, by `$ref` or by an `allOf` of one `$ref`.
function find_reference(schema)
    haskey(schema, "\$ref") && return String(last(split(schema["\$ref"], '/')))
    parts = get(schema, "allOf", nothing)
    parts === nothing && return nothing
    references = [part for part in parts if haskey(part, "\$ref")]
    length(references) == 1 || return nothing
    String(last(split(only(references)["\$ref"], '/')))
end

is_primitive_alternative(schema) =
    !haskey(schema, "properties") && find_reference(schema) === nothing &&
    get_alternatives(schema) === nothing &&
    get(schema, "type", nothing) in ("string", "integer", "number", "boolean", "null", "array")

# The tag of an alternative: the field with a constant value.
function find_tag(alternative)
    for (key, property) in get(alternative, "properties", Dict{String,Any}())
        haskey(property, "const") && return (key, property["const"])
    end
    nothing
end

is_ignored(name) = get(DEFINITIONS[name], "x-docs-ignore", false) === true

function get_form(name::String)
    definition = DEFINITIONS[name]
    alternatives = get_alternatives(definition)
    if alternatives === nothing
        type = get(definition, "type", nothing)
        (type == "object" || haskey(definition, "properties")) && return :object
        type in ("string", "integer", "number", "boolean") && return :alias
        return :free
    end
    all(is_primitive_alternative, alternatives) &&
        return any(alternative -> haskey(alternative, "const"), alternatives) ? :enum : :primitive_union
    any(alternative -> find_tag(alternative) !== nothing, alternatives) && return :tagged
    (!isempty(get(definition, "properties", Dict{String,Any}())) ||
     any(alternative -> find_reference(alternative) === nothing, alternatives)) && return :flat
    :structural
end

const FORMS = Dict(name => get_form(name) for name in DEFINITION_NAMES if !is_ignored(name))

# --- Fields ------------------------------------------------------------------

struct Field
    key::String
    name::String
    schema::Dict{String,Any}
    is_required::Bool
    description::String
end

function make_field_name(key::String)
    key == "_meta" && return "meta"
    name = lowercase(replace(key, r"(?<=[a-z0-9])([A-Z])" => s"_\1"))
    name in JULIA_KEYWORDS ? name * "_" : name
end

# The fields of an object: its own, then for a flat union the fields of each
# alternative, which are optional. `_meta` comes last.
function collect_fields(schema::Dict{String,Any}; is_required_kept::Bool = true)
    fields = Field[]
    required = Set{String}(get(schema, "required", String[]))
    for (key, property) in get_ordered_pairs(get(schema, "properties", Dict{String,Any}()))
        push!(fields, Field(key, make_field_name(key), property,
                            is_required_kept && key in required, get(property, "description", "")))
    end
    reference = find_reference(schema)
    if reference !== nothing && !haskey(schema, "\$ref")
        append!(fields, collect_fields(DEFINITIONS[reference]; is_required_kept))
    end
    alternatives = get_alternatives(schema)
    if alternatives !== nothing
        for alternative in alternatives
            find_tag(alternative) === nothing || continue
            append!(fields, collect_fields(_resolve(alternative); is_required_kept = false))
        end
    end
    merge_fields(fields)
end

_resolve(schema) = (reference = find_reference(schema);
                    reference === nothing || haskey(schema, "properties") ? schema :
                    merge(DEFINITIONS[reference], Dict{String,Any}("description" =>
                          get(schema, "description", get(DEFINITIONS[reference], "description", "")))))

# One field for each key, the first one kept, and `_meta` last.
function merge_fields(fields::Vector{Field})
    seen = Set{String}()
    merged = Field[]
    for field in fields
        field.key in seen && continue
        push!(seen, field.key)
        push!(merged, field)
    end
    vcat(filter(field -> field.key != "_meta", merged), filter(field -> field.key == "_meta", merged))
end

# The Julia type of a schema, as text.
function get_julia_type(schema)
    reference = find_reference(schema)
    reference === nothing || return get_definition_julia_type(reference)
    alternatives = get_alternatives(schema)
    if alternatives !== nothing
        others = filter(alternative -> get(alternative, "type", nothing) != "null", alternatives)
        (length(alternatives) == 2 && length(others) == 1) ||
            error("A field has an inline union: $(JSON.json(schema))")
        return "Union{Nothing,$(get_julia_type(only(others)))}"
    end
    type = get(schema, "type", nothing)
    if type isa Vector
        kinds = filter(!=("null"), type)
        length(kinds) == 1 || error("A field has many kinds: $(JSON.json(schema))")
        inner = get_julia_type(merge(schema, Dict{String,Any}("type" => only(kinds))))
        return "null" in type ? "Union{Nothing,$(inner)}" : inner
    end
    type == "string" && return "String"
    type == "integer" && return "Int"
    type == "number" && return "Float64"
    type == "boolean" && return "Bool"
    type == "null" && return "Nothing"
    type == "array" && return "Vector{$(get_julia_type(get(schema, "items", Dict{String,Any}())))}"
    if type == "object"
        extra = get(schema, "additionalProperties", nothing)
        extra isa Dict && !isempty(extra) && return "Dict{String,$(get_julia_type(extra))}"
        return "Dict{String,Any}"
    end
    type === nothing && return "Any"
    error("A field has an unknown type: $(JSON.json(schema))")
end

get_definition_julia_type(name::String) = FORMS[name] === :free ? "Any" : name

# --- Variants ----------------------------------------------------------------

struct Variant
    name::String
    tag::Union{Nothing,String}
    is_reused::Bool
    fields::Vector{Field}
    description::String
end

struct UnionForm
    name::String
    tag_key::Union{Nothing,String}
    variants::Vector{Variant}
    default::Union{Nothing,Variant}
    common_fields::Vector{Field}
end

# How many alternatives of the tagged and structural unions reference each
# definition.
const VARIANT_REFERENCE_COUNTS = let counts = Dict{String,Int}()
    for name in DEFINITION_NAMES
        get(FORMS, name, nothing) in (:tagged, :structural) || continue
        for alternative in get_alternatives(DEFINITIONS[name])
            reference = find_reference(alternative)
            reference === nothing || (counts[reference] = get(counts, reference, 0) + 1)
        end
    end
    counts
end

make_camel_name(text) = join(uppercasefirst.(split(replace(text, r"([a-z0-9])([A-Z])" => s"\1_\2"), r"[_\-/ ]+")))

function make_union_form(name::String)
    definition = DEFINITIONS[name]
    common_fields = collect_fields(Dict{String,Any}(
        "properties" => get(definition, "properties", Dict{String,Any}()),
        "required" => get(definition, "required", String[])))
    tag_key = nothing
    variants = Variant[]
    default = nothing
    for alternative in get_alternatives(definition)
        tag = find_tag(alternative)
        properties = get(alternative, "properties", Dict{String,Any}())
        # The alternative for a tag that the schema does not name is `Other<Union>`.
        if tag === nothing && any(other -> (other_tag = find_tag(other); other_tag !== nothing &&
                                            haskey(properties, first(other_tag))),
                                  get_alternatives(definition))
            continue
        end
        tag === nothing || (tag_key === nothing ? (tag_key = first(tag)) :
                            tag_key == first(tag) || error("$(name) has two tag keys"))
        reference = find_reference(alternative)
        inline = filter_ordered(pair -> tag === nothing || first(pair) != first(tag), properties)
        is_reused = reference !== nothing && isempty(inline) && isempty(common_fields) &&
                    get(FORMS, reference, nothing) === :object &&
                    get(VARIANT_REFERENCE_COUNTS, reference, 0) == 1
        variant_name = if is_reused
            reference
        elseif tag !== nothing
            get(VARIANT_NAMES, (name, string(last(tag))), name * make_camel_name(string(last(tag))))
        else
            name * make_camel_name(get(alternative, "title", something(reference, "Default")))
        end
        fields = Field[]
        append!(fields, common_fields)
        reference === nothing || append!(fields, collect_fields(DEFINITIONS[reference]))
        append!(fields, collect_fields(Dict{String,Any}("properties" => inline,
                                                        "required" => get(alternative, "required", String[]))))
        description = get(alternative, "description",
                          reference === nothing ? "" : get(DEFINITIONS[reference], "description", ""))
        variant = Variant(variant_name, tag === nothing ? nothing : string(last(tag)), is_reused,
                          merge_fields(fields), description)
        if tag === nothing && FORMS[name] === :tagged
            default === nothing || error("$(name) has two variants with no tag")
            default = variant
        end
        push!(variants, variant)
    end
    UnionForm(name, tag_key, variants, default, common_fields)
end

const UNION_FORMS = Dict(name => make_union_form(name) for name in DEFINITION_NAMES
                         if get(FORMS, name, nothing) in (:tagged, :structural))

# The union that each reused definition is a variant of.
const REUSED_VARIANT_UNIONS = Dict(variant.name => form.name for form in values(UNION_FORMS)
                                   for variant in form.variants if variant.is_reused)

# --- The method table --------------------------------------------------------

struct Method
    name::String
    side::String
    request::String
    response::Union{Nothing,String}
end

const METHODS = let methods = Dict{Tuple{String,String},Vector{String}}()
    for name in DEFINITION_NAMES
        definition = DEFINITIONS[name]
        haskey(definition, "x-method") || continue
        push!(get!(() -> String[], methods, (definition["x-side"], definition["x-method"])), name)
    end
    result = Method[]
    for ((side, method), names) in methods
        responses = filter(name -> endswith(name, "Response"), names)
        requests = filter(name -> !endswith(name, "Response"), names)
        length(requests) == 1 && length(responses) <= 1 || error("$(method) has the types $(names)")
        push!(result, Method(method, side, only(requests), isempty(responses) ? nothing : only(responses)))
    end
    sort!(result; by = method -> (method.side, method.name))
end

const METHOD_OF_TYPE = Dict(method.request => method for method in METHODS)
const METHOD_OF_RESPONSE = Dict(method.response => method for method in METHODS if method.response !== nothing)

# --- Text --------------------------------------------------------------------

escape_doc(text) = (occursin("\"\"\"", text) && error("A description holds three quotes.");
                    replace(text, "\\" => "\\\\", "\$" => "\\\$"))

indent(text, prefix) = join([isempty(line) ? line : prefix * line for line in split(text, '\n')], '\n')

function get_default_text(field::Field)
    value = get(field.schema, "const", nothing)
    value === nothing ? "nothing" : repr(value)
end

function format_signature(name::String, fields::Vector{Field})
    arguments = [field.is_required && !haskey(field.schema, "const") ? field.name :
                 "$(field.name) = $(get_default_text(field))" for field in fields]
    "$(name)(; $(join(arguments, ", ")))"
end

function format_field_docs(fields::Vector{Field})
    isempty(fields) && return ""
    lines = String["", "# Fields", ""]
    for field in fields
        type = get_julia_type(field.schema)
        mark = field.is_required ? "" : " (optional)"
        text = strip(field.description)
        entry = "- `$(field.name)::$(type)`$(mark)" * (isempty(text) ? "" : ": " * indent(text, "  ")[3:end])
        push!(lines, entry)
    end
    join(lines, '\n')
end

function format_method_doc(name::String)
    method = get(METHOD_OF_TYPE, name, nothing)
    if method !== nothing
        receiver = method.side == "protocol" ? "either side" : "the $(method.side)"
        return method.response === nothing ?
            "\n\nThe notification `$(method.name)`, which $(receiver) receives." :
            "\n\nThe request `$(method.name)`, which $(receiver) answers with a [`$(method.response)`](@ref)."
    end
    method = get(METHOD_OF_RESPONSE, name, nothing)
    method === nothing && return ""
    "\n\nThe answer of the request `$(method.name)`, a [`$(method.request)`](@ref)."
end

function write_doc(io, signature, description, extra = "")
    text = "    " * signature
    for part in (description, extra)
        part = strip(part)
        isempty(part) || (text *= "\n\n" * part)
    end
    println(io, "\"\"\"\n", escape_doc(text), "\n\"\"\"")
end

function write_view_type(io, name, supertype, fields, description; tag_key = nothing, tag = nothing,
                         union_name = nothing)
    signature = format_signature(name, fields)
    tag_text = tag === nothing ? "" :
               union_name === nothing ? "\n\nIts `$(tag_key)` is `$(repr(tag))`." :
               "\n\nIn a field of the type [`$(union_name)`](@ref), its `$(tag_key)` is `$(repr(tag))`."
    write_doc(io, signature, description, tag_text * format_method_doc(name) * format_field_docs(fields))
    println(io, "struct $(name) <: $(supertype)")
    println(io, "    json::Dict{String,Any}")
    println(io, "end")
    println(io)
end

function write_view_methods(io, name, fields; tag_key = nothing, tag = nothing)
    arguments = [field.is_required && !haskey(field.schema, "const") ? field.name :
                 "$(field.name) = $(get_default_text(field))" for field in fields]
    println(io, "function $(name)(; $(join(arguments, ", ")))")
    println(io, "    json = Dict{String,Any}()")
    tag === nothing || println(io, "    json[$(repr(tag_key))] = $(repr(tag))")
    for field in fields
        if field.is_required
            println(io, "    json[$(repr(field.key))] = _write_member($(get_julia_type(field.schema)), $(field.name))")
        else
            println(io, "    _write_optional!(json, $(repr(field.key)), $(get_julia_type(field.schema)), $(field.name))")
        end
    end
    println(io, "    $(name)(json)")
    println(io, "end")
    println(io)
    if !isempty(fields)
        println(io, "function Base.getproperty(object::$(name), name::Symbol)")
        println(io, "    json = getfield(object, :json)")
        for field in fields
            type = get_julia_type(field.schema)
            reader = if field.key == "_meta"
                "_read_meta(json)"
            elseif field.is_required
                "_read_required($(type), json, $(repr(field.key)), $(name))"
            elseif haskey(field.schema, "default") && field.schema["default"] !== nothing
                "something(_read_optional($(type), json, $(repr(field.key))), " *
                    "convert_from_json($(type), $(repr_json(field.schema["default"]))))"
            else
                "_read_optional($(type), json, $(repr(field.key)))"
            end
            println(io, "    name === :$(field.name) && return $(reader)")
        end
        println(io, "    getfield(object, name)")
        println(io, "end")
        println(io)
    end
    names = join([":" * field.name for field in fields], ", ")
    println(io, "Base.propertynames(::$(name), private::Bool = false) = ($(names)$(length(fields) == 1 ? "," : ""))")
    required = [field.key for field in fields if field.is_required]
    isempty(required) ||
        println(io, "_get_required_keys(::Type{$(name)}) = ($(join(repr.(required), ", "))$(length(required) == 1 ? "," : ""))")
    println(io)
end

# A JSON value as the Julia text of its plain value.
repr_json(value::Dict) = "Dict{String,Any}(" * join(["$(repr(key)) => $(repr_json(item))" for (key, item) in value], ", ") * ")"
repr_json(value::Vector) = "Any[" * join(repr_json.(value), ", ") * "]"
repr_json(value) = repr(value)

# --- The file ----------------------------------------------------------------

function write_types(io)
    println(io, "# This file is generated by gen/generate.jl from schema/schema.json, the schema")
    println(io, "# of the Agent Client Protocol, release $(SCHEMA_RELEASE). Do not change it: change")
    println(io, "# the generator and run it again.")
    println(io)
    println(io, "\"\"\"")
    println(io, "    SCHEMA_RELEASE")
    println(io)
    println(io, "The release of the schema of the Agent Client Protocol that the types follow.")
    println(io, "\"\"\"")
    println(io, "const SCHEMA_RELEASE = v\"$(SCHEMA_RELEASE)\"")
    println(io)

    # The abstract types of the unions come first, so a variant can name its supertype.
    for name in DEFINITION_NAMES
        form = get(UNION_FORMS, name, nothing)
        form === nothing && continue
        variants = join(["[`$(variant.name)`](@ref)" for variant in form.variants], ", ")
        rule = FORMS[name] === :tagged ?
            "The field `$(form.tag_key)` picks the variant" *
                (form.default === nothing ? "" : ", and an object without it is a [`$(form.default.name)`](@ref)") * "." :
            "The first variant whose required fields the object has is the variant."
        extra = "\n\nThe variants: $(variants), and [`Other$(name)`](@ref) for any other object. $(rule)" *
                format_method_doc(name) * format_field_docs(form.common_fields)
        write_doc(io, name, get(DEFINITIONS[name], "description", ""), extra)
        println(io, "abstract type $(name) <: ProtocolObject end")
        println(io)
    end

    for name in DEFINITION_NAMES
        form = get(FORMS, name, nothing)
        definition = DEFINITIONS[name]
        description = get(definition, "description", "")
        if form === :object || form === :flat
            haskey(REUSED_VARIANT_UNIONS, name) && continue
            write_view_type(io, name, "ProtocolObject", collect_fields(definition), description)
        elseif form in (:tagged, :structural)
            union_form = UNION_FORMS[name]
            for variant in union_form.variants
                write_view_type(io, variant.name, name, variant.fields,
                                variant.is_reused ? get(DEFINITIONS[variant.name], "description", "") :
                                                    variant.description;
                                tag_key = union_form.tag_key, tag = variant.tag,
                                union_name = variant.is_reused ? name : nothing)
            end
            other_doc = "A [`$(name)`](@ref) that this release of the schema does not name. It keeps " *
                        "the whole object."
            write_doc(io, "Other$(name)(json::Dict{String,Any})", other_doc)
            println(io, "struct Other$(name) <: $(name)")
            println(io, "    json::Dict{String,Any}")
            println(io, "end")
            println(io)
        end
    end

    # The aliases, the enums and the primitive unions, after the types that they name.
    for name in DEFINITION_NAMES
        form = get(FORMS, name, nothing)
        definition = DEFINITIONS[name]
        description = get(definition, "description", "")
        if form === :alias
            write_doc(io, name, description, "\n\nAn alias of `$(get_julia_type(definition))`.")
            println(io, "const $(name) = $(get_julia_type(definition))")
            println(io)
        elseif form === :enum
            alternatives = get_alternatives(definition)
            constants = filter(alternative -> haskey(alternative, "const"), alternatives)
            base = get_julia_type(Dict{String,Any}("type" => first(constants)["type"]))
            lines = ["- `$(repr(alternative["const"]))`" *
                     (haskey(alternative, "description") ?
                      ": " * indent(strip(alternative["description"]), "  ")[3:end] : "")
                     for alternative in constants]
            is_open = length(constants) < length(alternatives)
            extra = "\n\nAn alias of `$(base)`. The values:\n\n" * join(lines, '\n') *
                    (is_open ? "\n\nOther values can come too." : "")
            write_doc(io, name, description, extra)
            println(io, "const $(name) = $(base)")
            println(io)
        elseif form === :primitive_union
            types = [get_julia_type(alternative) for alternative in get_alternatives(definition)]
            write_doc(io, name, description, "\n\nAn alias of `Union{$(join(types, ","))}`.")
            println(io, "const $(name) = Union{$(join(types, ","))}")
            println(io)
        elseif form === :free
            write_doc(io, name, description, "\n\nAny JSON value.")
            println(io, "const $(name) = Any")
            println(io)
        end
    end

    # The named codes of an integer enum.
    for name in DEFINITION_NAMES
        get(FORMS, name, nothing) === :enum || continue
        constants = filter(alternative -> haskey(alternative, "const") && haskey(alternative, "title") &&
                                          alternative["const"] isa Integer,
                           get_alternatives(DEFINITIONS[name]))
        for alternative in constants
            constant = uppercase(replace(strip(alternative["title"]), r"[^A-Za-z0-9]+" => "_"))
            write_doc(io, constant, get(alternative, "description", ""), "\n\nA value of [`$(name)`](@ref).")
            println(io, "const $(constant) = $(alternative["const"])")
            println(io)
        end
    end

    # The constructors and the properties.
    for name in DEFINITION_NAMES
        form = get(FORMS, name, nothing)
        if form === :object || form === :flat
            haskey(REUSED_VARIANT_UNIONS, name) && continue
            write_view_methods(io, name, collect_fields(DEFINITIONS[name]))
        elseif form in (:tagged, :structural)
            union_form = UNION_FORMS[name]
            for variant in union_form.variants
                # A reused type gets its tag from the field of the union that holds it.
                write_view_methods(io, variant.name, variant.fields; tag_key = union_form.tag_key,
                                   tag = variant.is_reused ? nothing : variant.tag)
            end
            write_view_methods_of_other(io, union_form)
        end
    end

    # The reading of each union.
    for name in DEFINITION_NAMES
        form = get(FORMS, name, nothing)
        if form === :tagged
            union_form = UNION_FORMS[name]
            constant = "_" * uppercase(replace(name, r"([a-z0-9])([A-Z])" => s"\1_\2")) * "_VARIANTS"
            pairs_text = join(["$(repr(variant.tag)) => $(variant.name)"
                               for variant in union_form.variants if variant.tag !== nothing], ",\n    ")
            println(io, "const $(constant) = Dict{String,DataType}(\n    $(pairs_text))")
            println(io)
            for variant in union_form.variants
                variant.tag === nothing && continue
                println(io, "_find_variant_tag(::Type{$(name)}, ::Type{$(variant.name)}) = ",
                        "$(repr(union_form.tag_key)) => $(repr(variant.tag))")
            end
            println(io)
            default = union_form.default === nothing ? "nothing" : union_form.default.name
            println(io, "convert_from_json(::Type{$(name)}, value::AbstractDict) =")
            println(io, "    _read_tagged($(constant), $(default), Other$(name), $(repr(union_form.tag_key)), value)")
            println(io)
        elseif form === :structural
            union_form = UNION_FORMS[name]
            constant = "_" * uppercase(replace(name, r"([a-z0-9])([A-Z])" => s"\1_\2")) * "_VARIANTS"
            pairs_text = join(["$(variant.name) => $(repr([field.key for field in variant.fields if field.is_required]))"
                               for variant in union_form.variants], ",\n    ")
            println(io, "const $(constant) = Pair{DataType,Vector{String}}[\n    $(pairs_text)]")
            println(io)
            println(io, "convert_from_json(::Type{$(name)}, value::AbstractDict) =")
            println(io, "    _read_structural($(constant), Other$(name), value)")
            println(io)
        elseif form === :primitive_union
            println(io, "function convert_from_json(::Type{$(name)}, value)")
            for alternative in get_alternatives(DEFINITIONS[name])
                kind = alternative["type"]
                type = get_julia_type(alternative)
                if kind == "array" && haskey(get(alternative, "items", Dict{String,Any}()), "\$ref")
                    item = find_reference(alternative["items"])
                    keys = [key for key in get(DEFINITIONS[item], "required", String[])]
                    println(io, "    _is_json_kind(value, \"array\") && _has_first_item_keys(value, $(repr(keys))) &&")
                    println(io, "        return convert_from_json($(type), value)")
                else
                    println(io, "    _is_json_kind(value, $(repr(kind))) && return convert_from_json($(type), value)")
                end
            end
            println(io, "    _throw_shape_error($(name), value)")
            println(io, "end")
            println(io)
        end
    end

    # The method table.
    println(io, "# --- The methods ---------------------------------------------------------------")
    println(io)
    for method in METHODS
        println(io, "get_method_name(::Type{<:$(method.request)}) = $(repr(method.name))")
        method.response === nothing ||
            println(io, "get_response_type(::Type{<:$(method.request)}) = $(method.response)")
    end
    println(io)
    for (side, constant) in (("agent", "AGENT_METHOD_TYPES"), ("client", "CLIENT_METHOD_TYPES"),
                             ("protocol", "PROTOCOL_METHOD_TYPES"))
        entries = join(["$(repr(method.name)) => $(method.request)" for method in METHODS if method.side == side],
                       ",\n    ")
        receiver = side == "protocol" ? "either side receives" : "the $(side) receives"
        println(io, "# The methods that $(receiver): the type of the request or the notification of each.")
        println(io, "const $(constant) = Dict{String,DataType}(\n    $(entries))")
        println(io)
    end

    # The public names, which the module does not export because many are short.
    names = String["SCHEMA_RELEASE"]
    for name in DEFINITION_NAMES
        form = get(FORMS, name, nothing)
        form === nothing && continue
        push!(names, name)
        if form in (:tagged, :structural)
            append!(names, [variant.name for variant in UNION_FORMS[name].variants if !variant.is_reused])
            push!(names, "Other" * name)
        elseif form === :enum
            for alternative in get_alternatives(DEFINITIONS[name])
                haskey(alternative, "const") && haskey(alternative, "title") && alternative["const"] isa Integer &&
                    push!(names, uppercase(replace(strip(alternative["title"]), r"[^A-Za-z0-9]+" => "_")))
            end
        end
    end
    push!(names, "AGENT_METHOD_TYPES", "CLIENT_METHOD_TYPES", "PROTOCOL_METHOD_TYPES")
    lines = String[]
    line = "public"
    for (index, name) in enumerate(unique(names))
        piece = (index == 1 ? " " : ", ") * name
        if length(line) + length(piece) > 92
            push!(lines, line * ",")
            line = "    " * name
        else
            line *= piece
        end
    end
    push!(lines, line)
    println(io, join(lines, '\n'))
end

function write_view_methods_of_other(io, form::UnionForm)
    name = "Other" * form.name
    fields = form.common_fields
    if !isempty(fields)
        println(io, "function Base.getproperty(object::$(name), name::Symbol)")
        println(io, "    json = getfield(object, :json)")
        for field in fields
            type = get_julia_type(field.schema)
            reader = field.key == "_meta" ? "_read_meta(json)" :
                     field.is_required ? "_read_required($(type), json, $(repr(field.key)), $(name))" :
                     "_read_optional($(type), json, $(repr(field.key)))"
            println(io, "    name === :$(field.name) && return $(reader)")
        end
        println(io, "    getfield(object, name)")
        println(io, "end")
        println(io)
    end
    names = join([":" * field.name for field in fields], ", ")
    println(io, "Base.propertynames(::$(name), private::Bool = false) = ($(names)$(length(fields) == 1 ? "," : ""))")
    println(io)
end

# Each type name is used once.
let names = String[]
    for name in DEFINITION_NAMES
        form = get(FORMS, name, nothing)
        form === nothing && continue
        if form in (:tagged, :structural)
            push!(names, name, "Other" * name)
            append!(names, [variant.name for variant in UNION_FORMS[name].variants if !variant.is_reused])
        else
            push!(names, name)
        end
    end
    duplicates = [name for name in unique(names) if count(==(name), names) > 1]
    isempty(duplicates) || error("Two types have the name: $(duplicates)")
end

text = sprint(write_types)
write(TYPES_PATH, text)
println("Wrote $(TYPES_PATH): $(count(==('\n'), text)) lines.")
for (form, label) in ((:object, "objects"), (:flat, "flat unions"), (:tagged, "tagged unions"),
                      (:structural, "structural unions"), (:primitive_union, "primitive unions"),
                      (:enum, "enums"), (:alias, "aliases"), (:free, "free values"))
    println("  ", count(==(form), values(FORMS)), " ", label)
end
for name in sort(collect(keys(UNION_FORMS)))
    form = UNION_FORMS[name]
    println("  ", name, ": ", join([variant.name * (variant.is_reused ? "" : "*") for variant in form.variants], " "))
end
