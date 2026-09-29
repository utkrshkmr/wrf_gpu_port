! T-FMA (plan.md P0.5): the device must not contract a*b+c into a fused
! multiply-add.  Operands are read at run time (fma_cases.bin, written by
! gen_fma_cases.py) so they cannot be constant-folded.  Each record holds the
! bit patterns of a, b, c and of the unfused result round(round(a*b)+c).
! The file includes a = b = 1+2**-12, c = -1, where the unfused result is
! 2**-11 and the fused one 2**-11+2**-24.
!
! Pass: host result = device result = unfused result for every record.
! Run this test first: every other test assumes no contraction.
!
! Usage: t_fma [fma_cases.bin]

PROGRAM t_fma
   USE rm_testlib
   IMPLICIT NONE
   INTEGER(i4), ALLOCATABLE :: rec(:,:)
   REAL(r4), ALLOCATABLE :: a(:), b(:), c(:), dd(:), hd(:)
   REAL(r8), ALLOCATABLE :: a8(:), b8(:), c8(:), dd8(:), hd8(:)
   INTEGER(i8) :: n, k, nbad_h, nbad_d, nbad_d8
   INTEGER :: u, ios
   CHARACTER(LEN=256) :: path

   path = 'fma_cases.bin'
   IF (COMMAND_ARGUMENT_COUNT() >= 1) CALL GET_COMMAND_ARGUMENT(1, path)
   CALL require_device()
   OPEN (NEWUNIT=u, FILE=TRIM(path), ACCESS='STREAM', FORM='UNFORMATTED', STATUS='OLD', IOSTAT=ios)
   IF (ios /= 0) THEN
      PRINT '(a,a)', 'ERROR: cannot open ', TRIM(path)
      STOP 2
   END IF
   READ (u) n
   ALLOCATE (rec(4, n), a(n), b(n), c(n), dd(n), hd(n))
   READ (u) rec
   CLOSE (u)
   DO k = 1_i8, n
      a(k) = TRANSFER(rec(1, k), 1.0_r4)
      b(k) = TRANSFER(rec(2, k), 1.0_r4)
      c(k) = TRANSFER(rec(3, k), 1.0_r4)
   END DO

!$omp target teams distribute parallel do map(to: a, b, c) map(from: dd)
   DO k = 1_i8, n
      dd(k) = a(k)*b(k) + c(k)
   END DO
!$omp parallel do
   DO k = 1_i8, n
      hd(k) = a(k)*b(k) + c(k)
   END DO

   nbad_h = 0_i8
   nbad_d = 0_i8
   DO k = 1_i8, n
      IF (TRANSFER(hd(k), 0_i4) /= rec(4, k)) nbad_h = nbad_h + 1_i8
      IF (TRANSFER(dd(k), 0_i4) /= rec(4, k)) nbad_d = nbad_d + 1_i8
   END DO
   PRINT '(a,z8.8,a,z8.8,a,z8.8)', 'tie case: unfused=', rec(4, 1), ' host=', TRANSFER(hd(1), 0_i4), &
      ' device=', TRANSFER(dd(1), 0_i4)
   CALL report('T-FMA host REAL(4) (fused on host?)', nbad_h, n)
   CALL report('T-FMA device REAL(4) (fused on device?)', nbad_d, n)

   ! REAL(8): perturbed operands so that a*b is inexact; host and device
   ! (both unfused) must agree bit for bit.
   ALLOCATE (a8(n), b8(n), c8(n), dd8(n), hd8(n))
   a8 = REAL(a, r8) + 2.0_r8**(-40)
   b8 = REAL(b, r8) - 2.0_r8**(-41)
   c8 = REAL(c, r8)
!$omp target teams distribute parallel do map(to: a8, b8, c8) map(from: dd8)
   DO k = 1_i8, n
      dd8(k) = a8(k)*b8(k) + c8(k)
   END DO
!$omp parallel do
   DO k = 1_i8, n
      hd8(k) = a8(k)*b8(k) + c8(k)
   END DO
   nbad_d8 = 0_i8
   DO k = 1_i8, n
      IF (TRANSFER(dd8(k), 0_i8) /= TRANSFER(hd8(k), 0_i8)) nbad_d8 = nbad_d8 + 1_i8
   END DO
   CALL report('T-FMA REAL(8) host = device', nbad_d8, n)
   IF (nbad_h /= 0_i8 .OR. nbad_d /= 0_i8 .OR. nbad_d8 /= 0_i8) STOP 1
END PROGRAM t_fma
