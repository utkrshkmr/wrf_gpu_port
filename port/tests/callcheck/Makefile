# T-CALLCHECK: the call check of the island (WRF/frame/module_gpu_callcheck.F,
# port/tools/gen_island.py) on a mock routine.  Use run_callcheck.sh.
#   make                  nvfortran, target regions on the GPU
#   make COMPILER=gnu     gfortran, host only
COMPILER ?= nvhpc
TP       ?= haswell
W = ../../../WRF/frame
ifeq ($(COMPILER),nvhpc)
FC     = nvfortran
FFLAGS = -O2 -Kieee -Mnofma -tp=$(TP) -mp=gpu -gpu=cc80,cc90,nofma -Mpreprocess -DWRF_GPU
FREE   = -Mfree
else
FC     = gfortran
FFLAGS = -O2 -ffp-contract=off -ffree-line-length-none -fopenmp -cpp -DWRF_GPU
FREE   = -ffree-form
endif
OBJS = wrf_error_stub.o module_gpu_route.o module_gpu_callcheck.o
all: t_cc_ok t_cc_bug
wrf_error_stub.o: wrf_error_stub.F90
	$(FC) $(FFLAGS) -c $<
module_gpu_route.o: $(W)/module_gpu_route.F wrf_error_stub.o
	$(FC) $(FFLAGS) $(FREE) -c $(W)/module_gpu_route.F
module_gpu_callcheck.o: $(W)/module_gpu_callcheck.F module_gpu_route.o
	$(FC) $(FFLAGS) $(FREE) -c $(W)/module_gpu_callcheck.F
t_cc_ok: mock_gen.F90 t_callcheck.F90 $(OBJS)
	$(FC) $(FFLAGS) -c mock_gen.F90 -o mock_ok.o
	$(FC) $(FFLAGS) -o $@ t_callcheck.F90 mock_ok.o $(OBJS)
t_cc_bug: mock_gen.F90 t_callcheck.F90 $(OBJS) t_cc_ok
	$(FC) $(FFLAGS) -DMOCK_BUG -c mock_gen.F90 -o mock_bug.o
	$(FC) $(FFLAGS) -o $@ t_callcheck.F90 mock_bug.o $(OBJS)
clean:
	rm -f *.o *.mod t_cc_ok t_cc_bug
.PHONY: all clean
