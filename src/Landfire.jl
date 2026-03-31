module Landfire

using HTTP, JSON3, Extents, Dates, Downloads, Scratch, StyledStrings
using p7zip_jll: p7zip
import GeoInterface as GI

public healthcheck, products, Job, submit, cancel, status, extract, Dataset, files, attribute_table_url, attribute_table, full_product_url, filesize

dir() = Scratch.@get_scratch!("landfire_data")

#-----------------------------------------------------------------------------# constants
const BASE_URL = "https://lfps.usgs.gov/api"
const DOWNLOAD_BASE_URL = "https://landfire.gov/data-downloads"
const HEADER = Dict("Accept" => "application/json", "Content-Type" => "application/json")

#-----------------------------------------------------------------------------# attribute_table_url
const LAYERS = ["FBFM13", "FBFM40", "EVT", "EVC", "FVT", "FVC", "FRG", "SCLASS", "FDIST", "HDIST", "BPS"]

"""
    attribute_table_url(layer::String, year::Int=2024)
    attribute_table_url(product::Product)

Return the URL for the LANDFIRE attribute table CSV for the given layer and year.

Available layers: $(join(LAYERS, ", "))
"""
function attribute_table_url(layer::String, year::Int=2024)
    layer in LAYERS || error("Unknown layer: $layer. Available: $(join(LAYERS, ", "))")
    return "https://www.landfire.gov/sites/default/files/CSV/$year/LF$(year)_$layer.csv"
end

#-----------------------------------------------------------------------------# healthcheck
healthcheck() = JSON3.read(HTTP.get("$(BASE_URL)/healthCheck", HEADER).body)

#-----------------------------------------------------------------------------# Products
"""
A struct representing a product in the LANDFIRE API.
- Reference: [https://lfps.usgs.gov/products](https://lfps.usgs.gov/products)
"""
struct Product
    name::String
    theme::String
    layer::String
    version::String
    conus::Bool
    ak::Bool
    hi::Bool
    geoAreas::String
end
function Base.show(io::IO, p::Product)
    print(io, "Product: ", styled"{bright_cyan:$(p.name)} {bright_yellow:$(p.theme)}")
    print(io, styled" {bright_magenta:$(p.layer)}, {bright_black:$(p.version)}")
    for k in (:conus, :ak, :hi)
        getfield(p, k) ? print(io, styled" {bright_green:$(k)}") : print(io, styled" {bright_red:$(k)}")
    end
    print(io, " ", p.geoAreas)
end

function attribute_table_url(product::Product)
    for layer in LAYERS
        occursin(layer, product.layer) && return attribute_table_url(layer)
    end
    error("No attribute table found for product layer: $(product.layer)")
end

"""
    attribute_table(product::Product)
    attribute_table(layer::String, year::Int=2024)

Download and parse the LANDFIRE attribute table CSV for the given product or layer.

Returns a vector of `NamedTuple`s with column names from the CSV header.
"""
function attribute_table(layer::String, year::Int=2024)
    url = attribute_table_url(layer, year)
    _parse_csv(String(HTTP.get(url).body))
end

function attribute_table(product::Product)
    url = attribute_table_url(product)
    _parse_csv(String(HTTP.get(url).body))
end

function _parse_csv(csv::String)
    # Handle both Unix and Windows line endings
    csv = replace(csv, "\r\n" => "\n")
    csv = replace(csv, "\r" => "")
    lines = split(strip(csv), '\n')
    header = Symbol.(split(lines[1], ','))
    return map(lines[2:end]) do line
        values = split(line, ',')
        NamedTuple{Tuple(header)}(Tuple(values))
    end
end

products_cache_file() = joinpath(dir(), "products_cache.json")

# Fetch products from API and cache to file
function _fetch_and_cache_products()
    url = "$BASE_URL/products"
    response = HTTP.get(url, HEADER)
    write(products_cache_file(), response.body)
    return JSON3.read(response.body)
end

# Load products from cache or fetch if missing
function _load_products(; refresh::Bool=false)
    cache_file = products_cache_file()
    if refresh || !isfile(cache_file)
        @info refresh ? "Refreshing products cache..." : "Fetching products (no cache found)..."
        return _fetch_and_cache_products()
    end
    return JSON3.read(read(cache_file, String))
end

"""
    products(latest=true; refresh=false, kw...) -> Vector{Product}

Fetch and filter available products from the LANDFIRE API.

Returns a vector of `Product` structs sorted by name.  Results are cached locally;
use `refresh=true` to update the cache from the API.

## Keyword Arguments
- `refresh::Bool=false` - Set to `true` to refresh the cached product list from the API

Filter products by field values.  Boolean fields use exact matching, string fields use substring matching.
$(join(["- `$k::$v`" for (k,v) in zip(fieldnames(Product), fieldtypes(Product))], "\n"))

## Examples
```julia
products(conus=true)              # Only CONUS products
products(theme="Fuels")           # Products with "Fuels" in theme
products(layer="FBFM13")          # Products with "FBFM13" in layer name
products(conus=true, ak=false)    # CONUS only, not Alaska
products(refresh=true)            # Refresh cache and return all latest products
```
"""
function products(latest::Bool = true; refresh::Bool=false, kw...)
    obj = _load_products(; refresh)
    out = map(obj.products) do x
        Product(x.productName, x.theme, x.layerName, x.version, x.conus, x.ak, x.hi, x.geoAreas)
    end
    sort!(out, by = p -> p.name)
    # Apply keyword filters
    if !isempty(kw)
        filter!(out) do p
            all(kw) do (k, v)
                val = getfield(p, k)
                val isa Bool ? (val == v) : occursin(v, val)
            end
        end
    end
    if latest
        # Filter out year-specific editions (e.g., "Product Name 2019")
        filter!(p -> !occursin(r" \d{4}$", p.name), out)
        # Keep only the latest version of each product
        versions = Dict{String, Vector{String}}()
        for p in out
            push!(get!(versions, p.name, String[]), p.version)
        end
        filter!(out) do prod
            year(v) = let m = match(r"(\d{4})", v); m === nothing ? 0 : parse(Int, m[1]) end
            prod.version == versions[prod.name][argmax(year.(versions[prod.name]))]
        end
    end
    return out
end

#-----------------------------------------------------------------------------# Jobs
@kwdef struct Job
    email::String = haskey(ENV, "LANDFIRE_EMAIL") ? ENV["LANDFIRE_EMAIL"] : error("Please set LANDFIRE_EMAIL environment variable.")
    layers::Vector{Product}
    area_of_interest::String
    output_projection::Union{Nothing, String} = nothing
    resample_resolution::Union{Nothing, Int} = nothing
    edit_rule::Union{Nothing, String} = nothing
    edit_mask::Union{Nothing, String} = nothing
    priority_code::Union{Nothing, String} = nothing
end

Job(layers::Vector{Product}, aoi; kw...) = Job(; layers, area_of_interest = area_of_interest(aoi), kw...)

# Content-based hash for caching (Vector hash uses object identity by default)
function Base.hash(job::Job, h::UInt)
    h = hash(job.email, h)
    for layer in job.layers
        h = hash(layer.name, h)
        h = hash(layer.layer, h)
        h = hash(layer.version, h)
    end
    h = hash(job.area_of_interest, h)
    h = hash(job.output_projection, h)
    h = hash(job.resample_resolution, h)
    h = hash(job.edit_rule, h)
    h = hash(job.edit_mask, h)
    hash(job.priority_code, h)
end

"""
    area_of_interest(x)

Convert various input types to a string format suitable for the LANDFIRE API.

- `Integer`: Converted to string (represents a feature ID)
- `String`: Passed through unchanged (WKT or custom format)
- `Extents.Extent`: Converted to space-separated bounds `"xmin ymin xmax ymax"`
- Any geometry with `GeoInterface.extent`: Extracts extent and converts to bounds
"""
area_of_interest(x::Integer) = string(x)
area_of_interest(s::String) = s
area_of_interest((; X, Y)::Extents.Extent) = join(string.([X[1], Y[1], X[2], Y[2]]), ' ')
area_of_interest(geom) = area_of_interest(GI.extent(geom))

#-----------------------------------------------------------------------------# submit
"""
    submit(job::Job) --> job_id::String

Submits a job to the LANDFIRE API.  Returns the job ID as a string.
"""
function submit(job::Job)
    url = BASE_URL * "/job/submit"
    body = Dict(
        "Email" => job.email,
        "Layer_List" => join(map(x -> x.layer, job.layers), ';'),
        "Area_of_Interest" => job.area_of_interest,
    )
    isnothing(job.output_projection) || (body["Output_Projection"] = job.output_projection)
    isnothing(job.resample_resolution) || (body["Resample_Resolution"] = job.resample_resolution)
    isnothing(job.edit_rule) || (body["Edit_Rule"] = job.edit_rule)
    isnothing(job.edit_mask) || (body["Edit_Mask"] = job.edit_mask)
    isnothing(job.priority_code) || (body["Priority_Code"] = job.priority_code)
    res = HTTP.post(url, HEADER, JSON3.write(body))
    id = JSON3.read(res.body).jobId
    @info "Job submitted.  View job messages at: https://lfps.usgs.gov/job/$id"
    return id
end

#-----------------------------------------------------------------------------# cancel
"""
    cancel(job_id::String) --> obj::JSON3.Object
Cancels a submitted job.  Returns a JSON3.Object with job details.
"""
function cancel(job_id::String)
    url = BASE_URL * "/job/cancel"
    res = HTTP.get(url, HEADER; query=Dict("JobId" => job_id))
    JSON3.read(res.body)
end

#-----------------------------------------------------------------------------# status
"""
    status(job_id::String) --> obj::JSON3.Object

Queries the status of a submitted job.  Returns a JSON3.Object with job details.
If `obj.status == "Succeeded"`, the output zipfile can be downloaded from URL `obj.outputFile`.
"""
function status(job_id::String)
    url = BASE_URL * "/job/status"
    res = HTTP.get(url, HEADER; query=Dict("JobId" => job_id))
    JSON3.read(res.body)
end

#-----------------------------------------------------------------------------# download
"""
    download(job::Job; every=5, timeout=3600, file)

Submits a job to the LANDFIRE API, polls the job status every `every` seconds, and downloads the result.
When the job completes successfully, downloads and returns the path to the output zipfile.  The `timeout` parameter
specifies the maximum time (in seconds) to wait for the job to complete (default: 3600 = 1 hour).
"""
function download(job::Job; file=joinpath(dir(), "job_$(hash(job)).zip"), every::Integer=5, timeout::Integer=3600)
    id = submit(job)
    @info "Submitted job with ID: $id.  Checking job every $every seconds."
    start_time = time()
    while true
        for i in 1:every
            sleep(1)
            print('.')
        end
        if time() - start_time > timeout
            error("Job timed out after $timeout seconds. Job ID: $id")
        end
        obj = status(id)
        @info "Job Status: $(obj.status)"
        if obj.status == "Succeeded"
            file = Downloads.download(obj.outputFile, file)
            return file
        elseif obj.status == "Failed"
            error("Job failed: $(obj)")
        end
    end
end



"""
    extract(file, dir=tempdir())

Extract a 7zip archive to the specified directory using p7zip.  Returns the directory path.
"""
function extract(file::AbstractString, dir::AbstractString = tempdir())
    run(`$(p7zip()) x $file -o$dir -y`)
    return dir
end

#-----------------------------------------------------------------------------# Dataset
"""
    Dataset(products::Vector{Product}, aoi; dir=mktempdir(), kw...)

A convenience struct that encapsulates a complete LANDFIRE dataset download and extraction.

- `products`: Vector of `Product` structs to download
- `aoi`: Area of interest (see `Job` constructor for accepted formats)
- `kw...`: Additional keyword arguments passed to the `Job` constructor.

Files are cached in scratchspace based on the job hash, so repeated calls with the same parameters
will return the cached result without re-downloading.
"""
struct Dataset
    products::Vector{Product}
    job::Job
    file::String  # path to downloaded zipfile
    dir::String  # path to extracted directory

    function Dataset(products::Vector{Product}, aoi; kw...)
        job = Job(products, aoi; kw...)
        h = hash(job)
        new(products, job, joinpath(dir(), "job_$h.zip"), joinpath(dir(), "job_$h"))
    end
end

function Base.get(data::Dataset; every=5, timeout=3600)
    if !isdir(data.dir)
        @info "Downloading dataset to $(data.file)"
        download(data.job; file=data.file, every=every, timeout=timeout)
        @info "Extracting dataset to $(data.dir)"
        extract(data.file, data.dir)
    else
        @info "Using cached directory: $(data.dir)"
    end
    return only(filter(endswith(".tif"), readdir(data.dir; join=true)))
end

function Base.show(io::IO, data::Dataset)
    println(io, styled"{bright_cyan:Landfire.Dataset}")
    println(io, " Area of Interest: ", data.job.area_of_interest)
    for p in data.products
        println(io, " - ", p)
    end
end

"""
    files(data::Dataset)

Return a vector of absolute file paths for all files in the extracted dataset directory.
"""
files(data::Dataset) = readdir(data.dir; join=true)

#-----------------------------------------------------------------------------# Full Product Downloads
const REGIONS = ["CONUS", "AK", "HI"]

"""
    full_product_url(layer::String, region::String="CONUS", year::Int=2024)
    full_product_url(product::Product, region::String="CONUS")

Return the URL for downloading a full extent LANDFIRE product.

- `layer`: Layer name (e.g., "FBFM13", "EVT")
- `region`: Geographic region ("CONUS", "AK", or "HI")
- `year`: Product year (default: 2024)

## Example
```julia
url = Landfire.full_product_url("FBFM13", "CONUS", 2024)
# "https://landfire.gov/data-downloads/CONUS_LF2024/LF2024_FBFM13_CONUS.zip"

# Or from a Product (extracts layer name and year from product)
prod = Landfire.products(layer="FBFM13")[1]
url = Landfire.full_product_url(prod, "CONUS")
```
"""
function full_product_url(layer::String, region::String="CONUS", year::Int=2024)
    region = uppercase(region)
    region in REGIONS || error("Unknown region: $region. Available: $(join(REGIONS, ", "))")
    folder = "$(region)_LF$year"
    filename = "LF$(year)_$(layer)_$(region).zip"
    return "$DOWNLOAD_BASE_URL/$folder/$filename"
end

function full_product_url(product::Product, region::String="CONUS")
    # Extract base layer name by removing leading resolution digits (e.g., "250FBFM13" -> "FBFM13")
    layer = replace(product.layer, r"^\d+" => "")
    # Extract year from product name (e.g., "Fire Behavior Fuel Model 13 Anderson" with version "LF 2024")
    # or from version string which contains the year
    year_match = match(r"(\d{4})", product.version)
    year = isnothing(year_match) ? 2024 : parse(Int, year_match.captures[1])
    full_product_url(layer, region, year)
end

"""
    filesize(url::String) -> Int

Query the size of a remote file in bytes using an HTTP HEAD request.

Returns the file size, or throws an error if the size cannot be determined.

## Example
```julia
url = Landfire.full_product_url("FBFM13")
size = Landfire.filesize(url)
@info Base.format_bytes(size)
```
"""
function filesize(url::String)
    response = HTTP.head(url)
    content_length = HTTP.header(response, "Content-Length")
    isempty(content_length) && error("Server did not return Content-Length header")
    return parse(Int, content_length)
end


end # module
