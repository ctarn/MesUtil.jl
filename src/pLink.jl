module pLink

import CSV
import DataFrames
import MesMS
import RelocatableFolders: @path

import ..pFind

const DIR_DATA = @path joinpath(@__DIR__, "../data/pLink")

read_element(path=joinpath(DIR_DATA, "element.ini")) = pFind.read_element(path)
read_amino_acid(path=joinpath(DIR_DATA, "aa.ini")) = pFind.read_amino_acid(path)
read_mod(path=joinpath(DIR_DATA, "modification.ini")) = pFind.read_mod(path)

read_linker(path=joinpath(DIR_DATA, "xlink.ini")) = begin
    @info "Linker loading from " * path
    lines = map(strip, readlines(path)[begin+1:end])
    filter!(l -> !startswith(l, "name") && !startswith(l, "total") && !startswith(l, "[xlink]") && !isempty(l), lines)
    d = map(lines) do line
        name, attrs = map(strip, split(line, '='; limit=2))
        attrs = split(attrs)
        site_α = attrs[1]
        site_β = attrs[2]
        mass = parse(Float64, attrs[3])
        mass_mono = parse(Float64, attrs[5])
        comp = parse(MesMS.Formula, attrs[7])
        comp_mono = parse(MesMS.Formula, attrs[8])
        cleavable = parse(Bool, attrs[9])
        masses = [parse(Float64, attrs[10]), parse(Float64, attrs[11])]
        return Symbol(name) => (; site_α, site_β, mass, mass_mono, comp, comp_mono, cleavable, masses)
    end
    return Dict(d)
end

_parse_pair(pep, mods, prots) = begin
    pep_a, site_a, pep_b, site_b = match(r"^(\w+)\((\d+)\)-(\w+)\((\d+)\)$", pep).captures
    pep_a, pep_b = MesMS.unify_aa_seq(pep_a), MesMS.unify_aa_seq(pep_b)
    site_a, site_b = parse(Int, site_a), parse(Int, site_b)
    mod_a, mod_b = [], []
    if mods != "null"
        for mod in split(mods, ';'; keepempty=false)
            mod_type, mod_site = match(r"^(.+)\((\d+)\)$", String(mod)).captures
            mod_type = Symbol(mod_type)
            mod_site = parse(Int, mod_site)
            if mod_site <= length(pep_a) + 1
                push!(mod_a, (mod_type, mod_site))
            else
                push!(mod_b, (mod_type, mod_site - length(pep_a) - 3))
            end
        end
    end
    prot_a, prot_b = [], []
    prots = ismissing(prots) ? "" : prots
    for prot in split(prots, ")/"; keepempty=false)
        seq_a, site_seq_a, seq_b, site_seq_b = match(r"^(.+)\((\d+)\)-(.+)\((\d+)$", String(prot)).captures
        push!(prot_a, (strip(seq_a), parse(Int, site_seq_a)))
        push!(prot_b, (strip(seq_b), parse(Int, site_seq_b)))
    end
    return pep_a, mod_a, site_a, prot_a, pep_b, mod_b, site_b, prot_b
end

parse_pair(pep, mods, prots) = begin
    pep_a, mod_a, site_a, prot_a, pep_b, mod_b, site_b, prot_b = _parse_pair(pep, mods, prots)
    return vcat(sort([[pep_a, sort(mod_a), site_a, unique(prot_a)], [pep_b, sort(mod_b), site_b, unique(prot_b)]])...)
end

parse_pair(pep, mods, prots, extra_a, extra_b) = begin
    pep_a, mod_a, site_a, prot_a, pep_b, mod_b, site_b, prot_b = _parse_pair(pep, mods, prots)
    return vcat(sort([[pep_a, sort(mod_a), site_a, unique(prot_a), extra_a], [pep_b, sort(mod_b), site_b, unique(prot_b), extra_b]])...)
end

read_psm(path) = begin
    @info "pLink PSM reading from " * path
    df = DataFrames.DataFrame(CSV.File(path; delim=',', missingstring=nothing))
    if "Protein_Type" in names(df)
        DataFrames.rename!(df, :Protein_Type => :prot_type)
        if eltype(df.prot_type) <: Number
            df = df[df.prot_type .> 0, :]
        end
    end
    df.id = Vector{Int}(1:DataFrames.nrow(df))
    DataFrames.select!(df, :id, DataFrames.Not(:id))
    DataFrames.rename!(df, Dict(:Title => :title, :Charge => :z, Symbol("Precursor_Mass_Error(ppm)") => :error))
    ("Linker" in names(df)) && DataFrames.rename!(df, :Linker => :linker)
    ("Precursor_Mass" in names(df)) && DataFrames.rename!(df, :Precursor_Mass => :mh)
    ("Precursor_MH" in names(df)) && DataFrames.rename!(df, :Precursor_MH => :mh)
    ("Peptide_Mass" in names(df)) && DataFrames.rename!(df, :Peptide_Mass => :mh_calc)
    ("Peptide_MH" in names(df)) && DataFrames.rename!(df, :Peptide_MH => :mh_calc)
    ("Target_Decoy" in names(df)) && DataFrames.rename!(df, :Target_Decoy => :td)
    ("Q-value" in names(df)) && DataFrames.rename!(df, Symbol("Q-value") => :fdr)
    ("Score" in names(df)) && DataFrames.rename!(df, :Score => :score)
    ("Alpha_Matched" in names(df)) || (df.Alpha_Matched .= 0)
    ("Beta_Matched" in names(df)) || (df.Beta_Matched .= 0)
    src = [:Peptide, :Modifications, :Proteins, :Alpha_Matched, :Beta_Matched]
    dst = [:pep_a, :mod_a, :site_a, :prot_a, :match_a, :pep_b, :mod_b, :site_b, :prot_b, :match_b]
    DataFrames.transform!(df, src => DataFrames.ByRow(parse_pair) => dst)
    DataFrames.transform!(df, [:mh, :z] => DataFrames.ByRow(MesMS.mh_to_mz) => :mz)
    ("linker" in names(df)) && DataFrames.transform!(df, :linker => DataFrames.ByRow(Symbol) => :linker)
    ("fdr" in names(df)) && (df.fdr = df.fdr ./ 100)
    DataFrames.transform!(df, :title => DataFrames.ByRow(pFind.parse_title) => [:file, :scan, :idx_pre])
    return df
end

read_psm_full(path) = begin
    @info "pLink PSM (full list) reading from " * path
    df = DataFrames.DataFrame(CSV.File(path))
    DataFrames.select!(df, DataFrames.Not(
        ["Order", "FileID", "isComplexSatisfied", "isFilterIn"]
    ))
    DataFrames.rename!(df,
        :Title => :title, :Peptide => :pep, :Modifications => :mod,
        :Charge => :z, :Precursor_MH => :mh, :Peptide_MH => :mh_calc,
        Symbol("Precursor_Mass_Error(ppm)") => :error,
        Symbol("Precursor_Mass_Error(Da)") => :error_da,
        :Score => :score, :SVM_Score => :score_svm, :Refined_Score => :score_refined,
        :Target_Decoy => :td, Symbol("Q-value") => :fdr, Symbol("E-value") => :evalue,
        :Proteins => :prot, :Protein_Type => :prot_type,
    )
    DataFrames.transform!(df, [:mh, :z] => DataFrames.ByRow(MesMS.mh_to_mz) => :mz)
    DataFrames.transform!(df, [:mh_calc, :z] => DataFrames.ByRow(MesMS.mh_to_mz) => :mz_calc)
    DataFrames.transform!(df, :title => DataFrames.ByRow(pFind.parse_title) => [:file, :scan, :idx_pre])

    t = df.Peptide_Type
    DataFrames.select!(df, DataFrames.Not(:Peptide_Type))
    df_linear = df[t .== 0, :]
    df_mono = df[t .== 1, :]
    df_loop = df[t .== 2, :]
    df_xl = df[t .== 3, :]

    for d in [df_linear, df_mono, df_loop]
        td = fill(:Unknown, size(d, 1))
        td[d.td .== 0] .= :D
        td[d.td .== 2] .= :T
        d.td = td
    end

    td = fill(:Unknown, size(df_xl, 1))
    td[df_xl.td .== 0] .= :DD
    td[df_xl.td .== 1] .= :TD
    td[df_xl.td .== 2] .= :TT
    df_xl.td = td

    t = fill(:Unknown, size(df_xl, 1))
    t[df_xl.prot_type .== 1] .= :Intra
    t[df_xl.prot_type .== 2] .= :Inter
    df_xl.prot_type = t

    src = [:pep, :mod, :prot]
    dst = [:pep_a, :mod_a, :site_a, :prot_a, :pep_b, :mod_b, :site_b, :prot_b]
    DataFrames.transform!(df_xl, src => DataFrames.ByRow(parse_pair) => dst)
    DataFrames.select!(df_xl,
        :file, :scan, :idx_pre, :mh, :mz, :z, :pep_a, :pep_b, :site_a, :site_b, :mod_a, :mod_b,
        :td, :fdr, :prot_a, :prot_b, :title, DataFrames.Not(src),
    )
    return (; xl=df_xl, loop=df_loop, mono=df_mono, linear=df_linear)
end

parse_n_spec(path) = begin
    n_spec = 0
    open(path) do io
        for line in readlines(io)
            if startswith(line, "Spectra: ")
                n_spec = parse(Int, split(line)[end])
            end
        end
    end
    return n_spec
end

check_prot(cols, prots) = begin
    reduce(.&, map(c -> map(x -> any(p -> p[1] ∈ prots, x), c), cols))
end

pepstr(seq, mods, site) = begin
    if isempty(mods)
        return "$(seq)($(site))"
    else
        return "$(seq)($(site);$(join(["$(mod[1])@$(mod[2])" for mod in mods], ",")))"
    end
end

pepstr(seq_a, seq_b, mods_a, mods_b, site_a, site_b) = begin
    return pepstr(seq_a, mods_a, site_a) * "-" * pepstr(seq_b, mods_b, site_b)
end

calc_fdr(df) = begin
    tt, td, dd = 0, 0, 0
    fdr = zeros(DataFrames.nrow(df))
    for (i, row) in enumerate(DataFrames.eachrow(df))
        if row.td == 2
            tt += 1
        elseif row.td == 1
            td += 1
        elseif row.td == 0
            dd += 1
        else
            error("unexcepted td: $(row)")
        end
        fdr[i] = (td - dd) / tt
    end
    v = 1.0
    for i in length(fdr):-1:1
        v = min(v, fdr[i])
        fdr[i] = v
    end
    return fdr
end

end
