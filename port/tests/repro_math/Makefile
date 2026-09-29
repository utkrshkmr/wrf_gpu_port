# Host-vs-device tests of the reproducible math module (plan.md P0.5).
#
#   make                      nvfortran, OpenMP offload to A100 (cc80) and H100 (cc90)
#   make COMPILER=gnu         gfortran, host only: a compile check; run the
#                             programs with ALLOW_HOST=1
#   ./run_tests.sh            run all tests in order and write a results file
#
# TP is the host target used by every WRF build of the port (plan.md 4).

COMPILER ?= nvhpc
WRF      ?= ../../../WRF
TP       ?= haswell

ifeq ($(COMPILER),nvhpc)
FC     = nvfortran
FFLAGS = -O2 -Kieee -Mnofma -Mnoflushz -Mnodaz -Mvect=noassoc -tp=$(TP) \
         -mp=gpu -gpu=cc80,cc90,nofma,noflushz -Minfo=mp
else
FC     = gfortran
FFLAGS = -O2 -ffp-contract=off -fno-fast-math -ffree-line-length-none -fopenmp
endif

PROGS = t_fma t_ieee t_ipow t_rm_exh t_rm_pow t_rm_d

all: $(PROGS) fma_cases.bin

module_repro_math.f90: $(WRF)/frame/module_repro_math.F
	cpp -P -traditional-cpp -DREPRO_MATH $< > $@

module_repro_math.o: module_repro_math.f90
	$(FC) $(FFLAGS) -c $<

rm_testlib.o: rm_testlib.F90 module_repro_math.o
	$(FC) $(FFLAGS) -c $<

t_%: t_%.F90 rm_testlib.o module_repro_math.o
	$(FC) $(FFLAGS) -o $@ $< rm_testlib.o module_repro_math.o

fma_cases.bin: gen_fma_cases.py
	python3 gen_fma_cases.py -n 1000000 -o $@

clean:
	rm -f *.o *.mod module_repro_math.f90 $(PROGS) fma_cases.bin

.PHONY: all clean
