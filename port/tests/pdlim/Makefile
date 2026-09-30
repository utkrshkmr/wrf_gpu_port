# T-PDLIM (plan.md 7.5): split positive-definite limiter vs the original loop.
#
#   make                  nvfortran, target regions on the GPU (cc80, cc90)
#   make COMPILER=gnu     gfortran, host only; run with ALLOW_HOST=1
#   ./t_pdlim [ncases]    prints PASS/FAIL, exit status 0 on PASS
#
# The flags are the CPU-REF / GPU-REPRO flags of plan.md 4.

COMPILER ?= nvhpc
TP       ?= haswell

ifeq ($(COMPILER),nvhpc)
FC     = nvfortran
FFLAGS = -O2 -Kieee -Mnofma -Mnoflushz -Mnodaz -Mvect=noassoc -tp=$(TP) \
         -mp=gpu -gpu=cc80,cc90,nofma,noflushz -Minfo=mp
else
FC     = gfortran
FFLAGS = -O2 -ffp-contract=off -fno-fast-math -ffree-line-length-none -fopenmp
endif

all: t_pdlim

t_pdlim: t_pdlim.F90
	$(FC) $(FFLAGS) -o $@ $<

run: t_pdlim
	./t_pdlim 200

clean:
	rm -f *.o *.mod t_pdlim

.PHONY: all run clean
