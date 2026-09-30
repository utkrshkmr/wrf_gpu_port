# Worked, tested porting templates (plan.md 7.0; port/agent/CODING_STANDARD.md):
#   t_tmpl_b  Template B  rolling-buffer y-flux -> Y1/Y2 kernels   (advect_u)
#   t_tmpl_c  Template C  slab loops -> column kernel, range guards (calc_ww_cp)
#   t_tmpl_g  Template G  boundary strips, directives in place      (set_physical_bc3d)
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
# TMPL_B_FLAGS=-DTMPL_NO_STMTFN: statement functions as module functions (see t_tmpl_b.F90)
TMPL_B_FLAGS ?=
PROGS = t_tmpl_b t_tmpl_c t_tmpl_g
all: $(PROGS)
t_tmpl_b: t_tmpl_b.F90
	$(FC) $(FFLAGS) $(TMPL_B_FLAGS) -o $@ $<
t_%: t_%.F90
	$(FC) $(FFLAGS) -o $@ $<
run: $(PROGS)
	./t_tmpl_b 20 && ./t_tmpl_c 20 && ./t_tmpl_g 5
clean:
	rm -f *.o *.mod $(PROGS)
.PHONY: all run clean
