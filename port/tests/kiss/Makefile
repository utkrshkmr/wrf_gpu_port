# T-KISS (plan.md 8.5): KISS random numbers of RRTMG LW, host vs device.
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
FFLAGS = -O2 -ffp-contract=off -fno-fast-math -ffree-line-length-none -fopenmp -fwrapv
endif
all: t_kiss
t_kiss: t_kiss.F90
	$(FC) $(FFLAGS) -o $@ $<
run: t_kiss
	./t_kiss 1000000
clean:
	rm -f *.o *.mod t_kiss
.PHONY: all run clean
