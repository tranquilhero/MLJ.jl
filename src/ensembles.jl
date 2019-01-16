## WEIGHTED ENSEMBLES OF FITRESULTS

# L is the target element type
# R is atom fitresult type
# Atom is atomic model type, eg, DecisionTree
mutable struct WeightedEnsemble{R,Atom <: Supervised{R}} <: MLJType
    atom::Atom
    ensemble::Vector{R}
    weights::Vector{Float64}
end

_target_kind(Atom::Type{<:Model}) = (target_kind(Atom) == :numeric ? :numeric : :nominal)

# trait functions to dispatch predict method:
_target_is(Atom::Type{<:Deterministic}) = Val((:deterministic, _target_kind(Atom), target_quantity(Atom)))
_target_is(Atom::Type{<:Probabilistic}) =  Val((:probabilistic, _target_kind(Atom), target_quantity(Atom)))

predict(wens::WeightedEnsemble{R,Atom}, Xnew) where {R,Atom} = 
    predict(wens, Xnew, _target_is(Atom))

function predict(wens::WeightedEnsemble, Xnew, ::Val{(:deterministic, :nominal, :univariate)})
    ensemble = wens.ensemble
    atom = wens.atom

    n_atoms = length(ensemble)
    
    n_atoms > 0  || @error "Empty ensemble cannot make predictions."

    # TODO: make this more memory efficient but note that the type of
    # Xnew is unknown (ie, model dependent)
    predictions = reduce(hcat, [predict(atom, fitresult, Xnew) for fitresult in ensemble])
    null = categorical(levels(predictions))[1:0] # empty vector with all levels
    prediction = vcat(null, [mode(predictions[i,:]) for i in 1:size(predictions, 1)])
        
    return prediction
end

function predict(wens::WeightedEnsemble, Xnew, ::Val{(:deterministic, :numeric, :univariate)})
    ensemble = wens.ensemble
    weights = wens.weights
    
    atom = wens.atom

    n_atoms = length(ensemble)
    
    n_atoms > 0  || @error "Empty ensemble cannot make predictions."

    # TODO: make more memory efficient:
    predictions = reduce(hcat, [weights[k]*predict(atom, ensemble[k], Xnew) for k in 1:n_atoms])
    prediction =  [sum(predictions[i,:]) for i in 1:size(predictions, 1)]
            
    return prediction
end

function predict(wens::WeightedEnsemble, Xnew, ::Val{(:probabilistic, :nominal, :univariate)})

    ensemble = wens.ensemble
    weights = wens.weights
    
    atom = wens.atom

    n_atoms = length(ensemble)
    
    n_atoms > 0  || @error "Empty ensemble cannot make predictions."

    # TODO: make this more memory efficient but note that the type of
    # Xnew is unknown (ie, model dependent):

    # a matrix of probability distributions:
    predictions = reduce(hcat, [predict(atom, fitresult, Xnew) for fitresult in ensemble])
    n_rows = size(predictions, 1)

    # the weighted averages over the ensemble of the discrete pdf's:
    predictions  = [MLJBase.average([predictions[i,k] for k in 1:n_atoms], weights=weights) for i in 1:n_rows]

    return predictions
end

function predict(wens::WeightedEnsemble, Xnew, ::Val{(:probabilistic, :numeric, :univariate)})

    ensemble = wens.ensemble
    weights = wens.weights
    
    atom = wens.atom

    n_atoms = length(ensemble)
    
    n_atoms > 0  || @error "Empty ensemble cannot make predictions."

    # TODO: make this more memory efficient but note that the type of
    # Xnew is unknown (ie, model dependent):

    # a matrix of probability distributions:
    predictions = reduce(hcat, [predict(atom, fitresult, Xnew) for fitresult in ensemble])

    # n_rows = size(predictions, 1)
    # # the weighted average over the ensemble of the pdf means and pdf variances:
    # μs  = [sum([weights[k]*mean(predictions[i,k]) for k in 1:n_atoms]) for i in 1:n_rows]
    # σ2s = [sum([weights[k]*var(predictions[i,k]) for k in 1:n_atoms]) for i in 1:n_rows]

    # # a vector of normal probability distributions:
    # prediction = [Distributions.Normal(μs[i], sqrt(σ2s[i])) for i in 1:n_rows]

    prediction = [Distributions.MixtureModel(predictions[i,:], weights) for i in 1:size(predictions, 1)]

    return prediction
    
end


## CORE ENSEMBLE-BUILDING FUNCTION

function get_ensemble(atom::Supervised{R}, verbosity, X, ys, n, n_patterns, n_train, rng) where R
    
    ensemble = Vector{R}(undef, n)
    
    for i in 1:n
        verbosity < 1 || print("\rComputing regressor number: $i          ")
        train_rows = StatsBase.sample(rng, 1:n_patterns, n_train, replace=false)
        atom_fitresult, atom_cache, atom_report =
            fit(atom, verbosity - 1, X[Rows, train_rows], [y[train_rows] for y in ys]...)
        ensemble[i] = atom_fitresult
    end
    verbosity < 1 || println()
    
    return ensemble
    
end


## ENSEMBLE MODEL FOR DETERMINISTIC MODELS 

mutable struct DeterministicEnsembleModel{R,Atom<:Deterministic{R}} <: Deterministic{WeightedEnsemble{R,Atom}} 
    atom::Atom
    weight_regularization::Float64
    bagging_fraction::Float64
    rng_seed::Int
    n::Int
    parallel::Bool
end

function clean!(model::DeterministicEnsembleModel{R}) where R

    message = ""

    if model.bagging_fraction > 1 || model.bagging_fraction <= 0
        message = message*"`bagging_fraction` should be "*
        "in the range (0,1]. Reset to 1. "
        model.bagging_fraction = 1.0
    end
    if model.weight_regularization > 1 || model.weight_regularization < 0
        message = message*"`weight_regularization` should be "*
        "in the range [0,1]. Reset to 1. "
        model.weight_regularization = 1.0
    end
    if model.weight_regularization != 1.0 && target_kind(typeof(model.atom)) != :numeric
            message = message*"Weight deregularization not currently supported for models with nominal target; "*
            "Resetting weight_regularization to 1.0."
            model.weight_regularization = 1.0
    end

    return message

end
  
# constructor to infer type automatically:
DeterministicEnsembleModel(atom::Atom, weight_regularization,
                           bagging_fraction, rng_seed, n, parallel) where {R, Atom<:Deterministic{R}} =
                               DeterministicEnsembleModel{R, Atom}(atom, weight_regularization,
                                                                   bagging_fraction, rng_seed, n, parallel)

# lazy keyword constructors:
function DeterministicEnsembleModel(;atom=DeterministicConstantClassifier(), weight_regularization=1,
    bagging_fraction=0.8, rng_seed::Int=0, n::Int=100, parallel=true)
    
    model = DeterministicEnsembleModel(atom, weight_regularization, bagging_fraction, rng_seed, n, parallel)

    message = clean!(model)
    isempty(message) || @warn message
    
    return model
end

coerce(model::DeterministicEnsembleModel, Xtable) where R = coerce(model.atom, Xtable) 


## ENSEMBLE MODEL FOR PROBABILISTIC MODELS 

mutable struct ProbabilisticEnsembleModel{R,Atom<:Probabilistic{R}} <: Probabilistic{WeightedEnsemble{R,Atom}} 
    atom::Atom
    bagging_fraction::Float64
    rng_seed::Int
    n::Int
    parallel::Bool
end

function clean!(model::ProbabilisticEnsembleModel{R}) where R

    message = ""

    if model.bagging_fraction > 1 || model.bagging_fraction <= 0
        message = message*"`bagging_fraction` should be "*
        "in the range (0,1]. Reset to 1. "
        model.bagging_fraction = 1.0
    end

    return message

end
  
# constructor to infer type automatically:
ProbabilisticEnsembleModel(atom::Atom, bagging_fraction, rng_seed, n, parallel) where {R, Atom<:Probabilistic{R}} =
                               ProbabilisticEnsembleModel{R, Atom}(atom, bagging_fraction, rng_seed, n, parallel)

# lazy keyword constructor:
function ProbabilisticEnsembleModel(;atom=ConstantProbabilisticClassifier(), 
    bagging_fraction=0.8, rng_seed::Int=0, n::Int=100, parallel=true)
    
    model = ProbabilisticEnsembleModel(atom, bagging_fraction, rng_seed, n, parallel)

    message = clean!(model)
    isempty(message) || @warn message
    
    return model
end

coerce(model::ProbabilisticEnsembleModel, Xtable) where R = coerce(model.atom, Xtable) 


## COMMON CONSTRUCTOR

"""
    EnsembleModel(atom=nothing, bagging_fraction=0.8, rng_seed=0, n=100, parallel=true)

Create a model for training an ensemble of `n` learners, each with
associated model `atom`. Useful if `fit!(machine(atom, data...))` does
not create identical models every call (stochastic models, such as
DecisionTrees with randomized node selection criterion), or if
`bagging_fraction` is set to a value not equal to 1.0. The constructor
fails if no `atom` is specified.

The ensemble model is `Deterministic` or `Probabilistic`, according to
the corresponding supertype of `atom`. In the case of classifiers, the
prediction is based a majority vote, and for regressors it is the
usual average.  Probabilistic predictions are obtained by averaging
the atomic probability distribution functions; in particular, for
regressors, the ensemble prediction on each input pattern has type
`Distributions.MixtureModel{VF,VS,D}`, where `D` is the type of
predicted distribution for `atom`.

"""
function EnsembleModel(; args...)
    d = Dict(args)
    :atom in keys(d) || error("No atomic model specified. Use EnsembleModel(atom=...)")
    if d[:atom] isa Deterministic
        return DeterministicEnsembleModel(; d...)
    elseif d[:atom] isa Probabilistic
        return ProbabilisticEnsembleModel(; d...)
    end
    error("$(d[:atom]) does not appear to be a Supervised model.")
end



## THE COMMON FIT AND PREDICT METHODS

EitherEnsembleModel{R,Atom} = Union{DeterministicEnsembleModel{R,Atom}, ProbabilisticEnsembleModel{R,Atom}}

function fit(model::EitherEnsembleModel{R, Atom}, verbosity::Int, X, ys...) where {R,Atom<:Supervised{R}}

    parallel = model.parallel

    if model.rng_seed == 0
        seed = round(Int,time()*1000000)
    else
        seed = model.rng_seed
    end
    rng = MersenneTwister(seed)

    atom = model.atom
    n = model.n
    n_patterns = length(ys[1])
    n_train = round(Int, floor(model.bagging_fraction*n_patterns))

    if !parallel || nworkers() == 1 # build in serial
        ensemble = get_ensemble(atom, verbosity, X, ys, n, n_patterns, n_train, rng)
    else # build in parallel
        if verbosity >= 1
            println("Ensemble-building in parallel on $(nworkers()) processors.")
        end
        chunk_size = div(n, nworkers())
        left_over = mod(n, nworkers())
        ensemble =  @distributed (vcat) for i = 1:nworkers()
            if i != nworkers()
                get_ensemble(atom, verbosity - 1, X, ys, chunk_size, n_patterns, n_train, rng) # 0 means silent
            else
                get_ensemble(atom, verbosity - 1, X, ys, chunk_size + left_over, n_patterns, n_train, rng)
            end
        end
    end

    weights = fill(1/n, n)

    fitresult = WeightedEnsemble(model.atom, ensemble, weights)
    report = Dict{Symbol, Any}()
    report[:weights] = weights

    return fitresult, deepcopy(model), report
    
end

predict(model::EitherEnsembleModel, fitresult, Xnew) = predict(fitresult, Xnew)


#     # Optimize weights:

#     n = length(ensemble)
    
#     if model.weight_regularization == 1
#         weights = ones(n)/n
#         verbosity < 1 || @info "Weighting atoms uniformly."
#     else
#         verbosity < 1 || print("\nOptimizing weights...")
#         Y = Array{Float64}(undef, n, n_patterns)
#         for k in 1:n
#             Y[k,:] = predict(model.atom, ensemble[k], X, false, false)
#         end

#         # If I rescale all predictions by the same amount it makes no
#         # difference to the values of the optimal weights:
#         ybar = mean(abs.(y))
#         Y = Y/ybar
        
#         A = Y*Y'
#         b = Y*(y/ybar)

#         scale = abs(det(A))^(1/n)

#         if scale < eps(Float64)

#             verbosity < 0 || @warn "Weight optimization problem ill-conditioned. " *
#                  "Using uniform weights."
#             weights = ones(n)/n

#         else

#             # need regularization, `gamma`, between 0 and infinity:
#             if model.weight_regularization == 0 
#                 gamma = 0
#             else
#                 gamma = exp(atanh(2*model.weight_regularization - 1))
#             end
            
#             # add regularization and augment linear system for constraint
#             # (weights sum to one)
#             AA = hcat(A + scale*gamma*Matrix(I, n, n), ones(n))
#             AA = vcat(AA, vcat(ones(n), [0.0])')
#             bb = b + scale*gamma*ones(n)/n
#             bb = vcat(bb, [1.0])
            
#             weights = (AA \ bb)[1:n] # drop Lagrange multiplier
#             verbosity < 1 || println("\r$n weights optimized.\n")

#         end

#     end
                
#     fitresult = WeightedEnsemble(model.atom, ensemble, weights)
#     report = Dict{Symbol, Any}()
#     report[:normalized_weights] = weights*length(weights)

#     cache = (X, y, scheme_X, ensemble)
        
#     return fitresult, report, cache

# end

# predict(model::ProbabilisticEnsembleModel, fitresult, Xt, parallel, verbosity) =
#     predict(fitresult, Xt)

# function fit_weights!(mach::SupervisedMachine{WeightedEnsemble{R, Atom},
#                                               ProbabilisticEnsembleModel{R, Atom}};
#               verbosity=1, parallel=true) where {R, Atom <: Supervised{R}}

#     mach.n_iter != 0 || @error "Cannot fit weights to empty ensemble."

#     mach.fitresult, report, mach.cache =
#         fit(mach.model, mach.cache, false, parallel, verbosity;
#             optimize_weights_only=true)
#     merge!(mach.report, report)

#     return mach
# end

# function weight_regularization_curve(mach::SupervisedMachine{WeightedEnsemble{R, Atom},
#                                                            ProbabilisticEnsembleModel{R, Atom}},
#                                      test_rows;
#                                      verbosity=1, parallel=true,
#                                      range=range(0, stop=1, length=101),
#                                      raw=false) where {R, Atom <: Supervised{R}}

#     mach.n_iter > 0 || @error "No atoms in the ensemble. Run `fit!` first."
#     !raw || verbosity < 0 ||
#         @warn "Reporting errors for *transformed* target. Use `raw=false` "*
#              " to report true errors."

#     if parallel && nworkers() > 1
#         if verbosity >= 1
#             println("Optimizing weights in parallel on $(nworkers()) processors.")
#         end
#         errors = pmap(range) do w
#             verbosity < 2 || print("\rweight_regularization=$w       ")
#             mach.model.weight_regularization = w
#             fit_weights!(mach; parallel=false, verbosity=verbosity - 1)
#             err(mach, test_rows, raw=raw)
#         end
#     else
#         errors = Float64[]
#         for w in range
#             verbosity < 1 || print("\rweight_regularization=$w       ")
#             mach.model.weight_regularization = w
#             fit_weights!(mach; parallel= parallel, verbosity=verbosity - 1)
#             push!(errors, err(mach, test_rows, raw=raw))
#         end
#         verbosity < 1 || println()
        
#         mach.report[:weight_regularization_curve] = (range, errors)
#     end
    
#     return range, errors
# end


