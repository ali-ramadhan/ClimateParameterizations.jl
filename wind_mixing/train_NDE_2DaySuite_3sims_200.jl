using Statistics
using NCDatasets
using Plots
using Flux
using OceanParameterizations
using Oceananigans.Grids
using BSON
using OrdinaryDiffEq, DiffEqSensitivity
include("lesbrary_data.jl")
include("data_containers.jl")
include("animate_prediction.jl")

train_files = ["strong_wind", "strong_wind_weak_heating", "free_convection"]
output_gif_directory = "Output"

PATH = pwd()

𝒟train = data(train_files,
                    scale_type=ZeroMeanUnitVarianceScaling,
                    animate=false,
                    animate_dir="$(output_gif_directory)/Training")

uw_NN_model = BSON.load(joinpath(PATH, "Output", "uw_NN_params_2DaySuite.bson"))[:neural_network]
vw_NN_model = BSON.load(joinpath(PATH, "Output", "vw_NN_params_2DaySuite.bson"))[:neural_network]
wT_NN_model = BSON.load(joinpath(PATH, "Output", "wT_NN_params_2DaySuite.bson"))[:neural_network]

function predict_NDE(NN, x, top, bottom)
    interior = NN(x)
    return [top; interior; bottom]
end

f = 1f-4
H = Float32(abs(𝒟train.uw.z[end] - 𝒟train.uw.z[1]))
τ = Float32(abs(𝒟train.t[:,1][end] - 𝒟train.t[:,1][1]))
Nz = 32
u_scaling = 𝒟train.scalings["u"]
v_scaling = 𝒟train.scalings["v"]
T_scaling = 𝒟train.scalings["T"]
uw_scaling = 𝒟train.scalings["uw"]
vw_scaling = 𝒟train.scalings["vw"]
wT_scaling = 𝒟train.scalings["wT"]
μ_u = Float32(u_scaling.μ)
μ_v = Float32(v_scaling.μ)
σ_u = Float32(u_scaling.σ)
σ_v = Float32(v_scaling.σ)
σ_T = Float32(T_scaling.σ)
σ_uw = Float32(uw_scaling.σ)
σ_vw = Float32(vw_scaling.σ)
σ_wT = Float32(wT_scaling.σ)
uw_weights, re_uw = Flux.destructure(uw_NN_model)
vw_weights, re_vw = Flux.destructure(vw_NN_model)
wT_weights, re_wT = Flux.destructure(wT_NN_model)
uw_top = Float32(𝒟train.uw.scaled[1,1])
uw_bottom₁ = Float32(uw_scaling(-1e-3))
uw_bottom₂ = Float32(𝒟train.uw.scaled[end,1])
vw_top = Float32(𝒟train.vw.scaled[1,1])
vw_bottom = Float32(𝒟train.vw.scaled[end,1])
wT_top = Float32(𝒟train.wT.scaled[1,1])
wT_bottom₁ = Float32(𝒟train.wT.scaled[end,1])
wT_bottom₂ = Float32(wT_scaling(-4e-8))
wT_bottom₃ = Float32(wT_scaling(1.2e-7))
size_uw_NN = length(uw_weights)
size_vw_NN = length(vw_weights)
size_wT_NN = length(wT_weights)

uw_weights = BSON.load(joinpath(PATH, "Output", "uw_NDE_weights_2DaySuite.bson"))[:weights]
vw_weights = BSON.load(joinpath(PATH, "Output", "vw_NDE_weights_2DaySuite.bson"))[:weights]
wT_weights = BSON.load(joinpath(PATH, "Output", "wT_NDE_weights_2DaySuite.bson"))[:weights]

p₁ = [f; τ; H; μ_u; μ_v; σ_u; σ_v; σ_T; σ_uw; σ_vw; σ_wT; uw_top; uw_bottom₁; vw_top; vw_bottom; wT_top; wT_bottom₁; uw_weights; vw_weights; wT_weights]

D_cell = Float32.(Dᶜ(Nz, 1/Nz))

function NDE_nondimensional_flux(x, p, t)
    f, τ, H, μ_u, μ_v, σ_u, σ_v, σ_T, σ_uw, σ_vw, σ_wT, uw_top, uw_bottom, vw_top, vw_bottom, wT_top, wT_bottom = p[1:17]
    Nz = 32
    uw_weights = p[18:18+size_uw_NN-1]
    vw_weights = p[18+size_uw_NN:18+size_uw_NN+size_vw_NN-1]
    wT_weights = p[18+size_uw_NN+size_vw_NN:18+size_uw_NN+size_vw_NN+size_wT_NN-1]
    uw_NN = re_uw(uw_weights)
    vw_NN = re_vw(vw_weights)
    wT_NN = re_wT(wT_weights)
    A = - τ / H
    B = f * τ
    u = x[1:Nz]
    v = x[Nz+1:2*Nz]
    T = x[2*Nz+1:96]
    dx₁ = A .* σ_uw ./ σ_u .* D_cell * predict_NDE(uw_NN, x, uw_top, uw_bottom) .+ B ./ σ_u .* (σ_v .* v .+ μ_v) #nondimensional gradient
    dx₂ = A .* σ_vw ./ σ_v .* D_cell * predict_NDE(vw_NN, x, vw_top, vw_bottom) .- B ./ σ_v .* (σ_u .* u .+ μ_u)
    dx₃ = A .* σ_wT ./ σ_T .* D_cell * predict_NDE(wT_NN, x, wT_top, wT_bottom)
    return [dx₁; dx₂; dx₃]
end

function time_window(t, uvT, trange)
    return (Float32.(t[trange]), Float32.(uvT[:,trange]))
end

start_index = 1
end_index = 200

timesteps = start_index:5:end_index
uvT₁ = Float32.(𝒟train.uvT_scaled[:,start_index])
uvT₂ = Float32.(𝒟train.uvT_scaled[:,289 + start_index])
uvT₃ = Float32.(𝒟train.uvT_scaled[:,578 + start_index])


t_train, uvT_train₁ = time_window(𝒟train.t, 𝒟train.uvT_scaled, timesteps)
_, uvT_train₂ = time_window(𝒟train.t, 𝒟train.uvT_scaled[:, 290:end], timesteps)
_, uvT_train₃ = time_window(𝒟train.t, 𝒟train.uvT_scaled[:, 579:end], timesteps)
t_train = Float32.(t_train ./ τ)
tspan_train = (t_train[1], t_train[end])

opt_NDE = Tsit5()

prob₁ = ODEProblem(NDE_nondimensional_flux, uvT₁, tspan_train, p₁, saveat=t_train)
prob₂ = ODEProblem(NDE_nondimensional_flux, uvT₂, tspan_train, p₁, saveat=t_train)
prob₃ = ODEProblem(NDE_nondimensional_flux, uvT₃, tspan_train, p₁, saveat=t_train)

# sol₁ = solve(prob₁, opt_NDE)
# sol₂ = solve(prob₂, opt_NDE)

# Array(sol.t)

function loss_NDE_NN()
    p₁ = [f; τ; H; μ_u; μ_v; σ_u; σ_v; σ_T; σ_uw; σ_vw; σ_wT; uw_top; uw_bottom₁; vw_top; vw_bottom; wT_top; wT_bottom₁; uw_weights; vw_weights; wT_weights]
    p₂ = [f; τ; H; μ_u; μ_v; σ_u; σ_v; σ_T; σ_uw; σ_vw; σ_wT; uw_top; uw_bottom₁; vw_top; vw_bottom; wT_top; wT_bottom₂; uw_weights; vw_weights; wT_weights]
    p₃ = [f; τ; H; μ_u; μ_v; σ_u; σ_v; σ_T; σ_uw; σ_vw; σ_wT; uw_top; uw_bottom₂; vw_top; vw_bottom; wT_top; wT_bottom₃; uw_weights; vw_weights; wT_weights]
    
    _sol₁ = Array(solve(prob₁, opt_NDE, p=p₁, reltol=1f-5, saveat=t_train, sensealg=InterpolatingAdjoint(autojacvec=ZygoteVJP())))
    _sol₂ = Array(solve(prob₂, opt_NDE, p=p₂, reltol=1f-5, saveat=t_train, sensealg=InterpolatingAdjoint(autojacvec=ZygoteVJP())))
    _sol₃ = Array(solve(prob₃, opt_NDE, p=p₃, reltol=1f-5, saveat=t_train, sensealg=InterpolatingAdjoint(autojacvec=ZygoteVJP())))

    loss = mean(Flux.mse(_sol₁, uvT_train₁) + Flux.mse(_sol₂, uvT_train₂)+ Flux.mse(_sol₃, uvT_train₃))
    return loss
end

# loss_NDE_NN()

function cb_NDE()
    p₁ = [f; τ; H; μ_u; μ_v; σ_u; σ_v; σ_T; σ_uw; σ_vw; σ_wT; uw_top; uw_bottom₁; vw_top; vw_bottom; wT_top; wT_bottom₁; uw_weights; vw_weights; wT_weights]
    p₂ = [f; τ; H; μ_u; μ_v; σ_u; σ_v; σ_T; σ_uw; σ_vw; σ_wT; uw_top; uw_bottom₁; vw_top; vw_bottom; wT_top; wT_bottom₂; uw_weights; vw_weights; wT_weights]
    p₃ = [f; τ; H; μ_u; μ_v; σ_u; σ_v; σ_T; σ_uw; σ_vw; σ_wT; uw_top; uw_bottom₂; vw_top; vw_bottom; wT_top; wT_bottom₃; uw_weights; vw_weights; wT_weights]
    
    _sol₁ = Array(solve(prob₁, opt_NDE, p=p₁, reltol=1f-5, saveat=t_train, sensealg=InterpolatingAdjoint(autojacvec=ZygoteVJP())))
    _sol₂ = Array(solve(prob₂, opt_NDE, p=p₂, reltol=1f-5, saveat=t_train, sensealg=InterpolatingAdjoint(autojacvec=ZygoteVJP())))
    _sol₃ = Array(solve(prob₃, opt_NDE, p=p₃, reltol=1f-5, saveat=t_train, sensealg=InterpolatingAdjoint(autojacvec=ZygoteVJP())))

    loss = mean(Flux.mse(_sol₁, uvT_train₁) + Flux.mse(_sol₂, uvT_train₂)+ Flux.mse(_sol₃, uvT_train₃))
    @info loss
    return (_sol₁, _sol₂, _sol₃)
end

function save_NDE_weights()
    uw_NN_params = Dict(:weights => uw_weights)
    bson(joinpath(PATH, "Output", "uw_NDE_weights_2DaySuite_3Sims_$end_index.bson"), uw_NN_params)

    vw_NN_params = Dict(:weights => vw_weights)
    bson(joinpath(PATH, "Output", "vw_NDE_weights_2DaySuite_3Sims_$end_index.bson"), vw_NN_params)

    wT_NN_params = Dict(:weights => wT_weights)
    bson(joinpath(PATH, "Output", "wT_NDE_weights_2DaySuite_3Sims_$end_index.bson"), wT_NN_params)
end


function train_NDE(epochs)
    for i in 1:epochs
        @info "epoch $i/$epochs"
        Flux.train!(loss_NDE_NN, Flux.params(uw_weights, vw_weights, wT_weights), Iterators.repeated((), 2), ADAM(0.01), cb=Flux.throttle(cb_NDE,5))
        if i % 5 == 0
            save_NDE_weights()
        end
    end
    save_NDE_weights()
end

train_NDE(4000)

# @time Flux.train!(loss_NDE_NN, Flux.params(uw_weights, vw_weights, wT_weights), Iterators.repeated((), 2), ADAM(), cb=Flux.throttle(cb_NDE,2))

# loss_NDE_NN()

# function train_NDE(𝒟train, uw_NN_model, vw_NN_model, wT_NN_model, epochs=2, opt_NDE=ROCK4())
#     f = 1f-4
#     H = Float32(abs(𝒟train.uw.z[end] - 𝒟train.uw.z[1]))
#     τ = Float32(abs(𝒟train.t[:,1][end] - 𝒟train.t[:,1][1]))
#     Nz = 32
#     u_scaling = 𝒟train.scalings["u"]
#     v_scaling = 𝒟train.scalings["v"]
#     T_scaling = 𝒟train.scalings["T"]
#     uw_scaling = 𝒟train.scalings["uw"]
#     vw_scaling = 𝒟train.scalings["vw"]
#     wT_scaling = 𝒟train.scalings["wT"]
#     μ_u = Float32(u_scaling.μ)
#     μ_v = Float32(v_scaling.μ)
#     σ_u = Float32(u_scaling.σ)
#     σ_v = Float32(v_scaling.σ)
#     σ_T = Float32(T_scaling.σ)
#     σ_uw = Float32(uw_scaling.σ)
#     σ_vw = Float32(vw_scaling.σ)
#     σ_wT = Float32(wT_scaling.σ)
#     uw_weights, re_uw = Flux.destructure(uw_NN_model)
#     vw_weights, re_vw = Flux.destructure(vw_NN_model)
#     wT_weights, re_wT = Flux.destructure(wT_NN_model)
#     uw_top = Float32(𝒟train.uw.scaled[1,1])
#     uw_bottom = Float32(uw_scaling(-1f-3))
#     vw_top = Float32(𝒟train.vw.scaled[1,1])
#     vw_bottom = Float32(𝒟train.vw.scaled[end,1])
#     wT_top = Float32(𝒟train.wT.scaled[1,1])
#     wT_bottom = Float32(𝒟train.wT.scaled[end,1])
#     size_uw_NN = length(uw_weights)
#     size_vw_NN = length(vw_weights)
#     size_wT_NN = length(wT_weights)
#     p_nondimensional = [f; τ; H; μ_u; μ_v; σ_u; σ_v; σ_T; σ_uw; σ_vw; σ_wT; uw_top; uw_bottom; vw_top; vw_bottom; wT_top; wT_bottom; uw_weights; vw_weights; wT_weights]
#     D_cell = Float32.(Dᶜ(Nz, 1/Nz))

#     start_index = 1
#     end_index = 10
#     uvT₀ = Float32.(𝒟train.uvT_scaled[:,start_index])
#     tspan_train = (0f0, Float32.((𝒟train.t[end_index] - 𝒟train.t[start_index])/τ))

#     function time_window(t, uvT; startindex=1, stopindex)
#         if stopindex < length(t)
#             return (Float32.(t[startindex:stopindex]), Float32.(uvT[:,startindex:stopindex]))
#         else
#             @info "stop index larger than length of t"
#         end
#     end

#     t_train, uvT_train = time_window(𝒟train.t, 𝒟train.uvT_scaled, startindex=start_index, stopindex=end_index)
#     t_train ./= τ

#     function predict_NDE(NN, x, top, bottom)
#         interior = NN(x)
#         return [top; interior; bottom]
#     end


#     function NDE_nondimensional_flux!(dx, x, p, t)
#         f, τ, H, μ_u, μ_v, σ_u, σ_v, σ_T, σ_uw, σ_vw, σ_wT, uw_top, uw_bottom, vw_top, vw_bottom, wT_top, wT_bottom = p[1:17]
#         Nz = 32
#         uw_weights = p[18:18+size_uw_NN-1]
#         vw_weights = p[18+size_uw_NN:18+size_uw_NN+size_vw_NN-1]
#         wT_weights = p[18+size_uw_NN+size_vw_NN:end]
#         uw_NN = re_uw(uw_weights)
#         vw_NN = re_vw(vw_weights)
#         wT_NN = re_wT(wT_weights)
#         A = - τ / H
#         B = f * τ
#         u = x[1:Nz]
#         v = x[Nz+1:2*Nz]
#         T = x[2*Nz+1:end]
#         dx[1:Nz] .= A .* σ_uw ./ σ_u .* (D_cell * predict_NDE(uw_NN, x, uw_top, uw_bottom)) .+ B ./ σ_u .* (σ_v .* v .+ μ_v) #nondimensional gradient
#         dx[Nz+1:2*Nz] .= A .* σ_vw ./ σ_v .* (D_cell * predict_NDE(vw_NN, x, vw_top, vw_bottom)) .- B ./ σ_v .* (σ_u .* u .+ μ_u)
#         dx[2*Nz+1:end] .= A .* σ_wT ./ σ_T .* (D_cell * predict_NDE(wT_NN, x, wT_top, wT_bottom))
#     end

#     prob = ODEProblem(NDE_nondimensional_flux!, uvT₀, tspan_train, p_nondimensional, saveat=t_train)

#     function loss_NDE_NN()
#         p=[f; τ; H; μ_u; μ_v; σ_u; σ_v; σ_T; σ_uw; σ_vw; σ_wT; uw_top; uw_bottom; vw_top; vw_bottom; wT_top; wT_bottom; uw_weights; vw_weights; wT_weights]
#         _sol = Array(solve(prob, opt_NDE, p=p, reltol=1f-3, sense=InterpolatingAdjoint(autojacvec=ZygoteVJP())))
#         loss = Flux.mse(_sol, uvT_train)
#         return loss
#     end

#     function cb_NDE()
#         p=[f; τ; H; μ_u; μ_v; σ_u; σ_v; σ_T; σ_uw; σ_vw; σ_wT; uw_top; uw_bottom; vw_top; vw_bottom; wT_top; wT_bottom; uw_weights; vw_weights; wT_weights]
#         _sol = Array(solve(prob, opt_NDE, p=p, sense=InterpolatingAdjoint(autojacvec=ZygoteVJP())))
#         loss = Flux.mse(_sol, uvT_train)
#         @info loss
#         return _sol
#     end

#     Flux.train!(loss_NDE_NN, Flux.params(uw_weights, vw_weights, wT_weights), Iterators.repeated((), epochs), ADAM(0.01), cb=Flux.throttle(cb_NDE,2))

#     return uw_weights, vw_weights, wT_weights   
# end



# a, b, c = train_NDE(𝒟train, uw_NN_model, vw_NN_model, wT_NN_model)
# loss_NDE_NN()
# cb_NDE()