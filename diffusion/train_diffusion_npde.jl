using LinearAlgebra
using DiffEqFlux
using Flux
using Optim
using ClimateSurrogates

include("diffusion.jl")
include("diffusion_test.jl")
include("diffusion_npde.jl")

N = 16  # Number of grid points
L = 2   # Domain size -L/2 <= x <= L/2
κ = 1.5 # Diffusivity
T = 0.1 # Time span 0 <= T <= 0.1
Nt = 32 # Number of time snapshots to save
Δt = T/Nt

#####
##### Training and testing initial condition functions
#####

u₀_Gaussian(x) = exp(-50x^2)
u₀_quadratic(x) = 1 - x^2
u₀_sin(x) = 1 + sin(2π * x)
u₀_cos(x) = 1 - cos(2π * x)
u₀_shifted_sin(x) = 1 + sin(π * x + π/3)
u₀_shifted_cos(x) = 1 - cos(π * x - π/6)
u₀_zero(x) = 0.0
u₀_one(x) = 1.0

function_name(::typeof(u₀_Gaussian)) = "Gaussian"
function_name(::typeof(u₀_quadratic)) = "quadratic"
function_name(::typeof(u₀_sin))  = "sin"
function_name(::typeof(u₀_cos))  = "cos"
function_name(::typeof(u₀_shifted_sin))  = "shifted_sin"
function_name(::typeof(u₀_shifted_cos))  = "shifted_cos"
function_name(::typeof(u₀_zero)) = "zero"
function_name(::typeof(u₀_one)) = "one"

training_functions = (u₀_Gaussian, u₀_cos, u₀_shifted_sin, u₀_zero)
testing_functions = (u₀_quadratic, u₀_shifted_cos, u₀_sin, u₀_one)

solutions, training_solutions, testing_solutions =
    generate_solutions(training_functions, testing_functions, N=N, L=L, κ=κ, T=T, Nt=Nt, animate=false)

#####
##### Train and test a neural differential equation
#####

NN_dudt = generate_neural_pde_architecture(N, κ, type=:conservative_feed_forward)

# Set up neural differential equation
tspan = (0.0, T)
tsteps = range(tspan[1], tspan[2], length=Nt+1)
npde = NeuralODE(NN_dudt, tspan, Tsit5(), reltol=1e-3, saveat=tsteps)

for _ in 1:10
    for (name, sol) in training_solutions
        train_diffusion_neural_pde!(npde, sol, [ADAM(1e-2)])
    end
end

for _ in 1:10
    for (name, sol) in training_solutions
        train_diffusion_neural_pde!(npde, sol, [ADAM(1e-3)])
    end
end

for (name, sol) in solutions
    @info "Animating $name"
    animate_neural_pde_test(sol, npde, filename="NPDE_test_$name.mp4")
end