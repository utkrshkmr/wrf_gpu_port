# OpenMP offload feature probes (plan.md P0.5b).  Use run_probes.sh.
COMPILER ?= nvhpc
TP       ?= haswell
ifeq ($(COMPILER),nvhpc)
FC     = nvfortran
CC     = nvc
FFLAGS = -O2 -Kieee -Mnofma -tp=$(TP) -mp=gpu -gpu=cc80,cc90,nofma -Minfo=mp
CFLAGS = -O2 -DHAVE_CUDA -cuda
LDLIBS = -cuda
else
FC     = gfortran
CC     = gcc
FFLAGS = -O2 -fopenmp -ffree-line-length-none
CFLAGS = -O2
LDLIBS =
endif
PROBES = f_iftarget f_calls f_declmod f_present f_compmap f_compmap_member f_equiv f_data f_defmap f_defmap_neg f_privarr f_auto f_langfeat f_red f_stack
all: $(PROBES)
f_stack: f_stack.F90 stack_shim.o
	$(FC) $(FFLAGS) -o $@ f_stack.F90 stack_shim.o $(LDLIBS)
f_%: f_%.F90
	$(FC) $(FFLAGS) -o $@ $<
stack_shim.o: stack_shim.c
	$(CC) $(CFLAGS) -c $<
clean:
	rm -f *.o *.mod $(PROBES)
.PHONY: all clean
