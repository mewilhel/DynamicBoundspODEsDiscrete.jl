# Copyright (c) 2020: Matthew Wilhelm & Matthew Stuber.
# This work is licensed under the Creative Commons Attribution-NonCommercial-
# ShareAlike 4.0 International License. To view a copy of this license, visit
# http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to Creative
# Commons, PO Box 1866, Mountain View, CA 94042, USA.
#############################################################################
# Dynamic Bounds - pODEs Discrete
# A package for discretize and relax methods for bounding pODEs.
# See https://github.com/PSORLab/DynamicBoundspODEsDiscrete.jl
#############################################################################
# src/DiscretizeRelax/method/hermite_obreschkoff.jl
# Defines functions needed to perform a hermite_obreshkoff iteration.
#############################################################################

function mul_split!(Y::Vector{R}, A::Matrix{S}, B::Vector{T}, nx) where {R,S,T}
    if nx == 1
        @inbounds Y[1] = A[1,1]*B[1]
    else
        mul!(Y, A, B)
    end

    return nothing
end

function mul_split!(Y::Matrix{R}, A::Matrix{S}, B::Matrix{T}, nx) where {R,S,T}
    if nx == 1
        @inbounds Y[1,1] = A[1,1]*B[1,1]
    else
        mul!(Y, A, B)
    end

    return nothing
end

function copy_buffer!(y::CircularBuffer{T}, x::CircularBuffer{T}) where T
    y.capacity = x.capacity
    y.first = x.first
    y.length = x.length
    copyto!(y.buffer, x.buffer)

    return nothing
end

"""
$(TYPEDEF)

A structure that stores the cofficient of the (P,Q)-Hermite-Obreschkoff method.
(Offset due to method being zero indexed and Julia begin one indexed).
$(TYPEDFIELDS)
"""
struct HermiteObreschkoff <: AbstractStateContractorName
    "Cpq[i=1:p] index starting at i = 1 rather than 0"
    cpq::Vector{Float64}
    "Cqp[i=1:q] index starting at i = 1 rather than 0"
    cqp::Vector{Float64}
    "gamma for method"
    γ::Float64
    "Explicit order Hermite-Obreschkoff"
    p::Int64
    "Implicit order Hermite-Obreschkoff"
    q::Int64
    "Total order Hermite-Obreschkoff"
    k::Int64
end
function HermiteObreschkoff(p::Val{P}, q::Val{Q}) where {P, Q}
    temp_cpq = 1.0
    temp_cqp = 1.0
    cpq = zeros(P + 1)
    cqp = zeros(Q + 1)
    cpq[1] = temp_cpq
    cqp[1] = temp_cqp
    for i = 1:P
        temp_cpq *= (P - i + 1.0)/(P + Q - i + 1)
        cpq[i + 1] = temp_cpq
    end
    γ = 1.0
    for i = 1:Q
        temp_cqp *= (Q - i + 1.0)/(Q + P - i + 1)
        cqp[i + 1] = temp_cqp
        γ *= -i/(P+i)
    end
    K = P + Q + 1
    HermiteObreschkoff(cpq, cqp, γ, P, Q, K)
end
HermiteObreschkoff(p::Int, q::Int) = HermiteObreschkoff(Val(p), Val(q))

mutable struct HermiteObreschkoffFunctor{F <: Function, Pp1, Qp1, K, T <: Real, S <: Real, NY} <: AbstractStateContractor
    hermite_obreschkoff::HermiteObreschkoff
    η::Interval{T}
    μX::Vector{S}
    ρP::Vector{S}
    gⱼ₊₁::Vector{S}
    nx::Int64
    set_tf!_pred::TaylorFunctor!{F, K, T, S}
    real_tf!_pred::TaylorFunctor!{F, Pp1, T, T}
    Jf!_pred::JacTaylorFunctor!{F, Pp1, T, S, NY}
    Rⱼ₊₁::Vector{S}
    mRⱼ₊₁::Vector{T}
    f̃val_pred::Vector{Vector{T}}
    f̃_pred::Vector{Vector{S}}
    Vⱼ₊₁::Vector{S}
    X_predict::Vector{S}
    q_predict::Int64
    real_tf!_correct::TaylorFunctor!{F, Qp1, T, T}
    Jf!_correct::JacTaylorFunctor!{F, Qp1, T, S, NY}
    xval_correct::Vector{T}
    f̃val_correct::Vector{Vector{T}}
    sum_p::Vector{S}
    sum_q::Vector{S}
    Δⱼ₊₁::Vector{S}
end
function HermiteObreschkoffFunctor(f!::F, nx::Int, np::Int, p::Val{P}, q::Val{Q},
                                   s::S, t::T) where {F,P,Q,S,T}

    K = P + Q + 1
    hermite_obreschkoff = HermiteObreschkoff(p, q)
    η = Interval{T}(0.0,1.0)
    μX = zeros(S, nx)
    ρP = zeros(S, np)
    gⱼ₊₁ = zeros(S, nx)
    set_tf!_pred = TaylorFunctor!(f!, nx, np, Val(K), zero(S), zero(T))
    real_tf!_pred = TaylorFunctor!(f!, nx, np, Val(P), zero(T), zero(T))
    Jf!_pred = JacTaylorFunctor!(f!, nx, np, Val(P), zero(S), zero(T))
    Rⱼ₊₁ = zeros(S, nx)
    mRⱼ₊₁ = zeros(Float64, nx)

    f̃val_pred = Vector{Float64}[]
    for i = 1:(P + 1)
        push!(f̃val_pred, zeros(Float64, nx))
    end

    f̃_pred = Vector{S}[]
    for i = 1:(K + 1)
        push!(f̃_pred, zeros(S, nx))
    end

    Vⱼ₊₁ = zeros(S, nx)
    X_predict = zeros(S, nx)
    q_predict = P

    real_tf!_correct = TaylorFunctor!(f!, nx, np, Val(Q), zero(T), zero(T))
    Jf!_correct = JacTaylorFunctor!(f!, nx, np, Val(Q), zero(S), zero(T))
    xval_correct = zeros(Float64, nx)

    f̃val_correct = Vector{Float64}[]
    for i = 1:(Q + 1)
        push!(f̃val_correct, zeros(Float64, nx))
    end

    sum_p = zeros(S, nx)
    sum_q = zeros(S, nx)
    P1 = P + 1
    Q1 = Q + 1

    Δⱼ₊₁ = zeros(S, nx)

    HermiteObreschkoffFunctor{F, P1, Q1, K+1, T, S, nx + np}(hermite_obreschkoff, η, μX, ρP, gⱼ₊₁, nx,
                                                             set_tf!_pred, real_tf!_pred, Jf!_pred, Rⱼ₊₁,
                                                             mRⱼ₊₁, f̃val_pred, f̃_pred, Vⱼ₊₁,
                                                             X_predict, q_predict, real_tf!_correct,
                                                             Jf!_correct, xval_correct, f̃val_correct,
                                                             sum_p, sum_q, Δⱼ₊₁)
end

function state_contractor(m::HermiteObreschkoff, f, Jx!, Jp!, nx, np, style, s, h)
    HermiteObreschkoffFunctor(f, nx, np, Val(m.p), Val(m.q), style, s)
end
state_contractor_k(m::HermiteObreschkoff) = m.k
state_contractor_γ(m::HermiteObreschkoff) = m.γ
state_contractor_steps(m::HermiteObreschkoff) = 2

function hermite_obreschkoff_predictor!(d::HermiteObreschkoffFunctor{F,P1,Q1,K,T,S,NY},
                                        contract::ContractorStorage{S}) where {F,P1,Q1,K,T,S,NY}

    hⱼ = contract.hj_computed
    t = contract.times[1]
    q = d.q_predict
    k = d.hermite_obreschkoff.k
    nx = d.nx

    set_tf! = d.set_tf!_pred
    real_tf! = d.real_tf!_pred
    Jf!_pred = d.Jf!_pred

    # computes Rj and it's midpoint
    set_tf!(d.f̃_pred, contract.Xj_apriori, contract.P, t)
    hjq = hⱼ^(q + 1)
    for i = 1:nx
        @inbounds d.Rⱼ₊₁[i] = hjq*d.f̃_pred[q + 2][i]
        @inbounds d.mRⱼ₊₁[i] = mid(d.Rⱼ₊₁[i])
    end

    # defunes new x point... k corresponds to k - 1 since taylor
    # coefficients are zero indexed
    real_tf!(d.f̃val_pred, contract.xval, contract.pval, t)
    hji1 = 0.0
    fill!(d.Vⱼ₊₁, 0.0)
    for i = 1:q
        hji1 = hⱼ^i
        @__dot__ d.Vⱼ₊₁ += hji1*d.f̃val_pred[i + 1]
    end
    d.Vⱼ₊₁ += contract.xval

    # compute extensions of taylor cofficients for rhs
    μ!(d.μX, contract.Xj_0, contract.xval, d.η)
    ρ!(d.ρP, contract.P, contract.pval, d.η)
    set_JxJp!(Jf!_pred, d.μX, d.ρP, t)
    for i = 1:(q + 1)
        hji1 = hⱼ^(i - 1)
        if i == 1
            fill!(Jf!_pred.Jxsto, zero(S))
            for j = 1:nx
                Jf!_pred.Jxsto[j,j] = one(S)
            end
        else
            @__dot__ Jf!_pred.Jxsto += hji1*Jf!_pred.Jx[i]
        end
        @__dot__ Jf!_pred.Jpsto += hji1*Jf!_pred.Jp[i]
    end

    # update x floating point value
    d.X_predict = d.Vⱼ₊₁ + d.Rⱼ₊₁ + (Jf!_pred.Jxsto*contract.A[2].Q)*contract.Δ[1] + Jf!_pred.Jpsto*contract.rP
    @show d.X_predict

    return nothing
end

function (d::HermiteObreschkoffFunctor{F,P1,Q1,K,T,S,NY})(contract::ContractorStorage{S},
                                                          result::StepResult{S}) where {F, P1, Q1, K, T, S, NY}

    println("    ")
    println("    ")

    hermite_obreschkoff_predictor!(d, contract)

    @__dot__ d.xval_correct = mid(d.X_predict)

    # extract method constants
    ho = d.hermite_obreschkoff
    γ = ho.γ
    p = ho.p
    q = ho.q
    k = ho.k
    nx = d.nx

    hⱼ = contract.hj_computed
    t = contract.times[1]
    hjk = hⱼ^k

    fill!(d.sum_p, zero(S))
    for i = 1:(p + 1)
        coeff = ho.cpq[i]*hⱼ^(i-1)
        @__dot__ d.sum_p += coeff*d.f̃val_pred[i]
    end

    d.real_tf!_correct(d.f̃val_correct, d.xval_correct, contract.pval, t)
    fill!(d.sum_q, zero(S))
    for i = 1:(q + 1)
        coeff = ho.cqp[i]*(-hⱼ)^(i-1)
        @__dot__ d.sum_q += coeff*d.f̃val_correct[i]
    end
    δⱼ₊₁ = d.sum_p - d.sum_q + γ*hjk*d.f̃_pred[k + 1]

    # Sj,+
    Jf!_pred = d.Jf!_pred
    fill!(Jf!_pred.Jxsto, zero(S))
    fill!(Jf!_pred.Jpsto, zero(S))
    for i = 1:(p + 1)
        hji1 = ho.cpq[i]*hⱼ^(i - 1)
        @__dot__ Jf!_pred.Jxsto += hji1*Jf!_pred.Jx[i]
        @__dot__ Jf!_pred.Jpsto += hji1*Jf!_pred.Jp[i]
    end

    # compute Sj+1,-
    Jf!_correct = d.Jf!_correct
    μ!(d.μX, d.X_predict, d.xval_correct, d.η)
    ρ!(d.ρP, contract.P, contract.pval, d.η)
    set_JxJp!(Jf!_correct, d.μX, d.ρP, t)
    for i = 1:(q + 1)
        hji1 = ho.cqp[i]*(-hⱼ)^(i - 1)
        @__dot__ Jf!_correct.Jxsto += hji1*Jf!_correct.Jx[i]
        @__dot__ Jf!_correct.Jpsto += hji1*Jf!_correct.Jp[i]
    end

    precond = inv(mid.(Jf!_correct.Jxsto))
    B = precond*(Jf!_pred.Jxsto*contract.A[2].Q)
    C = I - precond*Jf!_correct.Jxsto
    Uj = d.X_predict - d.xval_correct
    Jpdiff = Jf!_pred.Jpsto - Jf!_correct.Jpsto
    Cp = precond*Jpdiff

    @show "contract 1", contract.Δ[1]
    X_computed = d.xval_correct + B*contract.Δ[1] + C*Uj + Cp*contract.rP + precond*δⱼ₊₁
    contract.X_computed = X_computed .∩ d.X_predict
    @__dot__ contract.xval_computed = mid(contract.X_computed)

    # calculation block for computing Aⱼ₊₁ and inv(Aⱼ₊₁)
    Aⱼ₊₁ = contract.A[1]
    contract.B = mid.(Jf!_correct.Jxsto*contract.A[2].Q)
    calculateQ!(Aⱼ₊₁, contract.B, nx)
    calculateQinv!(Aⱼ₊₁)

    precond2 = Aⱼ₊₁.inv*precond
    Uj2 = contract.X_computed - d.xval_correct
    B2 = precond*(Jf!_pred.Jxsto*contract.A[2].Q)
    d.Δⱼ₊₁ = precond2*δⱼ₊₁ + precond2*Jpdiff*contract.rP + B2*contract.Δ[1] + Aⱼ₊₁.inv*C*Uj2
    @show d.Δⱼ₊₁

    pushfirst!(contract.Δ, d.Δⱼ₊₁)
    @show "contract 2", contract.Δ[1]

    @show contract.X_computed

    return RELAXATION_NOT_CALLED
end


get_Δ(f::HermiteObreschkoffFunctor) = f.Δⱼ₊₁
function set_x!(out::Vector{Float64}, f::HermiteObreschkoffFunctor)
    out .= f.Jf!_correct.xⱼ₊₁
    return nothing
end
function set_X!(out::Vector{S}, f::HermiteObreschkoffFunctor) where S
    out .= f.Jf!_correct.Xⱼ₊₁
    return nothing
end

has_jacobians(d::HermiteObreschkoffFunctor) = true
function extract_jacobians!(d::HermiteObreschkoffFunctor, ∂f∂x::Vector{Matrix{T}},
                            ∂f∂p::Vector{Matrix{T}}) where {T <: Real}
    for i = 1:d.lon.set_tf!.k+1
        ∂f∂x[i] .= d.lon.jac_tf!.Jx[i]
        ∂f∂p[i] .= d.lon.jac_tf!.Jp[i]
    end
    return nothing
end

function get_jacobians!(d::HermiteObreschkoffFunctor, ∂f∂x::Vector{Matrix{T}},
                        ∂f∂p::Vector{Matrix{T}}, Xⱼ, P, t) where {T <: Real}
    set_JxJp!(d.lon.jac_tf!, Xⱼ, P, t[1])
    extract_jacobians!(d, ∂f∂x, ∂f∂p)
    return nothing
end
