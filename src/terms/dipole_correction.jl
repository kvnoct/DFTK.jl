using Statistics
using Infiltrator

# papis open "bengtsson 1999"
# https://wiki.fysik.dtu.dk/gpaw/tutorials/dipole_correction/dipole.html
# https://gitlab.com/gpaw/gpaw/-/blob/master/gpaw/dipole_correction.py
# https://gitlab.com/gpaw/gpaw/-/blob/master/gpaw/grid_descriptor.py
# https://gitlab.com/gpaw/gpaw/-/blob/master/gpaw/density.py


Base.@kwdef struct SurfaceDipoleCorrection
    normal_axis::Int = 3  # Cartesian axis which is normal to the surface
    width::Real = 1.8     # Width of the dipole layer (in Bohr)
end
function (dip::SurfaceDipoleCorrection)(basis)
    TermSurfaceDipoleCorrection(basis, dip.normal_axis, dip.width)
end


struct TermSurfaceDipoleCorrection <: Term
    basis::PlaneWaveBasis
    normal_axis::Int          # Axes normal to the slab
    slab_axes::Vector{Int}    # Axes along which the slab extends
    sawtooth::AbstractArray   # Sawtooth potential across normal_axis
end
function TermSurfaceDipoleCorrection(basis, normal_axis, width)
    lattice   = basis.model.lattice
    slab_axes = [α for α = 1:3 if α != normal_axis]
    if !iszero(lattice[normal_axis, slab_axes]) || !iszero(lattice[slab_axes, normal_axis])
        error("Slab axes $slab_axes need to be orthogonal to remaining axis ($normal_axis). " *
              "Check your lattice.")
    end

    T  = eltype(basis)
    Nz = basis.fft_size[normal_axis]
    Lz = abs(basis.model.lattice[normal_axis, normal_axis])
    sawtooth = smooth_sawtooth(T.(0:Nz-1) ./ Nz, T(width) / Lz)
    TermSurfaceDipoleCorrection(basis, normal_axis, slab_axes, sawtooth)
end


function ene_ops(term::TermSurfaceDipoleCorrection, ψ, occ; ρ, kwargs...)
    basis   = term.basis
    lattice = basis.model.lattice
    dVol = basis.model.unit_cell_volume / prod(basis.fft_size)
    Nz = basis.fft_size[term.normal_axis]
    Lz = abs(lattice[term.normal_axis, term.normal_axis])
    Nz1 = basis.fft_size[1]
    Lz1 = abs(lattice[1, 1])
    Nz2 = basis.fft_size[2]
    Lz2 = abs(lattice[2, 2])
    T  = eltype(basis)


    # What QE does:
    #
    # alat = lattice
    # bmod=SQRT(bg(1,edir)**2+bg(2,edir)**2+bg(3,edir)**2)
    #  P_{ele} = \sum_{ijk} \rho_{r_{ijk}} Saw\left( \frac{k}{nr3} \right)
    #                    \frac{alat}{bmod} \frac{\Omega}{nrxx} \frac{4\pi}{\Omega}
    #
    # alat = 1.0
    # bmod = Lz
    # dip = P_{ele} + P_{nuc}
    # eamp = 0
    # E_{TOT} = -e^{2} \left( eamp - dip \right) dip \frac{\Omega}{4\pi}

    # charge = dipmom / length of lattice along z
    #

    model = basis.model
    ccharge = DFTK.center_of_charge(model.atoms)
    polarisation  = compute_dipole_moment(basis, ρ, center=ccharge)
    dipmom_z = polarisation[3] * model.unit_cell_volume
    println("   dip2   ", dipmom_z)



    # weirdshift(x) = mod(x + 1.5, 1.0) - 0.5
    # weirdshift(x) = x - 0.5

    @assert size(ρ, 4) == 1
    ρ = dropdims(ρ, dims=4)

    # # Compute electronic dipole moment of ρ along term.normal_axis
    # ρ_z       = vec(sum(ρ; dims=term.slab_axes))
    # ρ_z1      = vec(sum(ρ; dims=[2, 3]))
    # ρ_z2      = vec(sum(ρ; dims=[1, 3]))
    # dipmom_z  = -dot(ρ_z, @. weirdshift(T(0:Nz-1) / Nz) * Lz )    * dVol  # Lz  / Nz
    # dipmom_z1 = -dot(ρ_z1, @. weirdshift(T(0:Nz1-1)/ Nz1) * Lz1 ) * dVol # Lz1 / Nz1
    # dipmom_z2 = -dot(ρ_z2, @. weirdshift(T(0:Nz2-1)/ Nz2) * Lz2 ) * dVol # Lz2 / Nz2

    # println("   dip   ", dipmom_z1/DFTK.units.Å, "  ", dipmom_z2/DFTK.units.Å, "  ", dipmom_z  /DFTK.units.Å)
    # ops = [NoopOperator(term.basis, kpoint) for kpoint in term.basis.kpoints]


    # dip_v = dens.calculate_dipole_moment()
    # c = self.c
    # L = gd.cell_cv[c, c]
    # self.correction = 2π * dip_v[c] * L / gd.volume
    # vHt_q -= 2 * self.correction * self.sawtooth_q

    surface_dipole_density = dipmom_z * Lz / basis.model.unit_cell_volume
    println("surf dip dens   ", surface_dipole_density)
    Vdip = zero(ρ) .- 4π * surface_dipole_density .* reshape(term.sawtooth, 1, 1, :)
    @assert term.normal_axis == 3
    ops = [NoopOperator(term.basis, kpoint) for kpoint in term.basis.kpoints]
    # return (E=0, ops=ops)

    # TODO
    # V = Vdip
    # E = energy from Vdip + Ecdip

    E = sum(Vdip .* ρ) / 2 * dVol
    @show E
    # @infiltrate
    ops = [RealSpaceMultiplication(basis, kpoint, Vdip) for kpoint in basis.kpoints]
    (E=E, ops=ops)
end


"""
Smoothened sawtooth function on the periodic domain [0, 1] (i.e. fractional coordinates).
`width` controls the width of the region attributed to smoothly connecting the
extremal points of the sawtooth to make a continuous-differentiable function.
Same as `x`, `width` is in fractional coordinates.
"""
function smooth_sawtooth(x, width=0.0)
    sawtooth = x .- 0.5
    @assert width < 1.0
    if width > 0
        whalf = width / 2
        # Third degree polynomial fitted such that P(0) = 0 (periodic across boundary),
        # P(whalf) = sawtooth(whalf), P'(whalf) = sawtooth'(whalf) (smooth)
        a = 1 - 3 / 4whalf
        b = 1 / (4whalf^3)
        P(x) = x * (a + b * x^2)

        # The number of gridpoints we need to overwrite with P(x) either side:
        gp = ceil(Int, whalf * length(x))
        sawtooth[1:gp] .= P.(@view x[1:gp])
        sawtooth[end-gp+1:end] .= -reverse(@view sawtooth[1:gp])
    end
    sawtooth
end