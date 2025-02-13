using Pkg
Pkg.activate(@__DIR__)
CI = get(ENV, "CI", nothing) == "true"
using Documenter, NCDatasets, CommonDataModel

makedocs(
    modules = [NCDatasets, CommonDataModel],
    sitename = "NCDatasets.jl",
    doctest = false,
    format = Documenter.HTML(
        prettyurls = CI,
    ),
    pages = [
        "Introduction" => "index.md",
        "Datasets" => "dataset.md",
        "Dimensions" => "dimensions.md",
        "Variables" => "variables.md",
        "Attributes" => "attributes.md",
        "Performance tips" => "performance.md",
        "Known issues" => "issues.md",
        "Experimental features" => "experimental.md",
        "Tutorials" => "tutorials.md",
    ],
    checkdocs = :none,
)

if CI
    deploydocs(repo = "github.com/Alexander-Barth/NCDatasets.jl.git",
               target = "build")
end
