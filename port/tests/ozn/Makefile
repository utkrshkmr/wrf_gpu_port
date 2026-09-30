# T-OZN (plan.md 8.5, K-OZP): ozone interpolation, original vs row-parallel version.
#   make                  nvfortran, target regions on the GPU
#   make COMPILER=gnu     gfortran, host only; run with ALLOW_HOST=1
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
all: t_ozn
t_ozn: t_ozn.F90
	$(FC) $(FFLAGS) -o $@ $<
run: t_ozn
	./t_ozn 20
clean:
	rm -f *.o *.mod t_ozn
.PHONY: all run clean
