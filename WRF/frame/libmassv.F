! IBM libmassv compatibility library
! 

#ifndef NATIVE_MASSV
      subroutine vdiv(z,x,y,n)
      real*8 x(*),y(*),z(*)
      do 10 j=1,n
      z(j)=x(j)/y(j)
   10 continue
      return
      end

      subroutine vsdiv(z,x,y,n)
      real*4 x(*),y(*),z(*)
      do 10 j=1,n
      z(j)=x(j)/y(j)
   10 continue
      return
      end

      subroutine vexp(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_exp(x(j))
   10 continue
      return
      end

      subroutine vsexp(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_exp(x(j))
   10 continue
      return
      end

      subroutine vlog(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_log(x(j))
   10 continue
      return
      end

      subroutine vslog(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_log(x(j))
   10 continue
      return
      end

      subroutine vrec(y,x,n)
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=1.d0/x(j)
   10 continue
      return
      end

      subroutine vsrec(y,x,n)
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=1.e0/x(j)
   10 continue
      return
      end

      subroutine vrsqrt(y,x,n)
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=1.d0/sqrt(x(j))
   10 continue
      return
      end

      subroutine vsrsqrt(y,x,n)
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=1.e0/sqrt(x(j))
   10 continue
      return
      end

      subroutine vsincos(x,y,z,n)
   USE module_repro_math
      real*8 x(*),y(*),z(*)
      do 10 j=1,n
      x(j)=rp_sin(z(j))
      y(j)=rp_cos(z(j))
   10 continue
      return
      end

      subroutine vssincos(x,y,z,n)
   USE module_repro_math
      real*4 x(*),y(*),z(*)
      do 10 j=1,n
      x(j)=rp_sin(z(j))
      y(j)=rp_cos(z(j))
   10 continue
      return
      end

      subroutine vsqrt(y,x,n)
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=sqrt(x(j))
   10 continue
      return
      end

      subroutine vssqrt(y,x,n)
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=sqrt(x(j))
   10 continue
      return
      end

      subroutine vtan(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_tan(x(j))
   10 continue
      return
      end

      subroutine vstan(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_tan(x(j))
   10 continue
      return
      end

      subroutine vatan2(z,y,x,n)
   USE module_repro_math
      real*8 x(*),y(*),z(*)
      do 10 j=1,n
      z(j)=rp_atan2(y(j),x(j))
   10 continue
      return
      end

      subroutine vsatan2(z,y,x,n)
   USE module_repro_math
      real*4 x(*),y(*),z(*)
      do 10 j=1,n
      z(j)=rp_atan2(y(j),x(j))
   10 continue
      return
      end

      subroutine vasin(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_asin(x(j))
   10 continue
      return
      end

      subroutine vsin(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_sin(x(j))
   10 continue
      return
      end

      subroutine vssin(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_sin(x(j))
   10 continue
      return
      end

      subroutine vacos(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_acos(x(j))
   10 continue
      return
      end

      subroutine vcos(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_cos(x(j))
   10 continue
      return
      end

      subroutine vscos(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_cos(x(j))
   10 continue
      return
      end

      subroutine vcosisin(y,x,n)
   USE module_repro_math
      complex*16 y(*)
      real*8 x(*)
      do 10 j=1,n
      y(j)=dcmplx(rp_cos(x(j)),rp_sin(x(j)))
   10 continue
      return
      end

      subroutine vscosisin(y,x,n)
   USE module_repro_math
      complex*8 y(*)
      real*4 x(*)
      do 10 j=1,n
      y(j)= cmplx(rp_cos(x(j)),rp_sin(x(j)))
   10 continue
      return
      end

      subroutine vdint(y,x,n)
      real*8 x(*),y(*)
      do 10 j=1,n
!     y(j)=dint(x(j))
      y(j)=int(x(j))
   10 continue
      return
      end

      subroutine vdnint(y,x,n)
      real*8 x(*),y(*)
      do 10 j=1,n
!     y(j)=dnint(x(j))
      y(j)=nint(x(j))
   10 continue
      return
      end

      subroutine vlog10(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_log10(x(j))
   10 continue
      return
      end

!      subroutine vlog1p(y,x,n)
!      real*8 x(*),y(*)
!      interface
!        real*8 function log1p(%val(x))
!          real*8 x
!        end function log1p
!      end interface
!      do 10 j=1,n
!      y(j)=log1p(x(j))
!   10 continue
!      return
!      end

      subroutine vcosh(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_cosh(x(j))
   10 continue
      return
      end

      subroutine vsinh(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_sinh(x(j))
   10 continue
      return
      end

      subroutine vtanh(y,x,n)
   USE module_repro_math
      real*8 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_tanh(x(j))
   10 continue
      return
      end

!      subroutine vexpm1(y,x,n)
!      real*8 x(*),y(*)
!      interface
!        real*8 function expm1(%val(x))
!          real*8 x
!        end function expm1
!      end interface 
!      do 10 j=1,n
!      y(j)=expm1(x(j))
!   10 continue
!      return
!      end


      subroutine vsasin(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_asin(x(j))
   10 continue
      return
      end

      subroutine vsacos(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
#if defined (G95)
! no reason why g95 should fail - oh well, we don't use this routine anyways
      y(j)=rp_asin( sqrt(1-x(j)*x(j)) )
#else
      y(j)=rp_acos(x(j))
#endif
   10 continue
      return
      end

      subroutine vscosh(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_cosh(x(j))
   10 continue
      return
      end

!      subroutine vsexpm1(y,x,n)
!      real*4 x(*),y(*)
!      interface
!        real*8 function expm1(%val(x))
!          real*8 x
!        end function expm1
!      end interface
!      do 10 j=1,n
!      y(j)=expm1(real(x(j),8))
!   10 continue
!      return
!      end

      subroutine vslog10(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_log10(x(j))
   10 continue
      return
      end

!      subroutine vslog1p(y,x,n)
!      real*4 x(*),y(*)
!      interface
!        real*8 function log1p(%val(x))
!          real*8 x
!        end function log1p
!      end interface
!      do 10 j=1,n
!      y(j)=log1p(real(x(j),8))
!   10 continue
!      return
!      end


      subroutine vssinh(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_sinh(x(j))
   10 continue
      return
      end

      subroutine vstanh(y,x,n)
   USE module_repro_math
      real*4 x(*),y(*)
      do 10 j=1,n
      y(j)=rp_tanh(x(j))
   10 continue
      return
      end
#endif

      subroutine vspow(z,y,x,n)
   USE module_repro_math
      real*4 x(*),y(*),z(*)
      do 10 j=1,n
      z(j)=rp_pow(y(j), x(j))
   10 continue
      return
      end

      subroutine vpow(z,y,x,n)
   USE module_repro_math
      real*8 x(*),y(*),z(*)
      do 10 j=1,n
      z(j)=rp_pow(y(j), x(j))
   10 continue
      return
      end

