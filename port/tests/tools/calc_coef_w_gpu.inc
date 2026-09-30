#ifdef WRF_GPU
! K-CCW (plan.md 7.4): one thread per (i,j) column; cof(i) becomes the private scalar cofs
!$omp target teams distribute parallel do collapse(2) if(target: gpu_on(R_CALC_COEF_W)) default(none) &
!$omp& shared(a,alpha,gamma,mut,c1h,c2h,c1f,c2f,cqw,rdn,rdnw,c2a) &
!$omp& firstprivate(i_start,i_end,j_start,j_end,kde,dts,g,epssm,lid_flag) private(k,kk,b,c,cofs)
      DO j = j_start, j_end
      DO i = i_start, i_end
        k = kde-1
        cofs  = (.5*dts*g*(1.+epssm))**2
        a(i, 2 ,j) = 0.
        a(i,kde,j) =-2.*cofs*rdnw(kde-1)**2*c2a(i,kde-1,j)*lid_flag/((c1h(k)*MUT(i,j)+c2h(k))*(c1f(k)*MUT(i,j)+c2f(k)))
        gamma(i,1 ,j) = 0.
        DO kk=3,kde-1
          k=kk-1
          a(i,kk,j) =   -cqw(i,kk,j)*cofs*rdn(kk)* rdnw(kk-1)*c2a(i,kk-1,j)/((c1h(k)*MUT(i,j)+c2h(k))*(c1f(k)*MUT(i,j)+c2f(k)))
        ENDDO
        DO k=2,kde-1
          b = 1.+cqw(i,k,j)*cofs*rdn(k)*(rdnw(k  )*c2a(i,k,  j)/((c1h(k)*MUT(i,j)+c2h(k))*(c1f(k)*MUT(i,j)+c2f(k)))  &
                                          +rdnw(k-1)*c2a(i,k-1,j)/((c1h(k-1)*MUT(i,j)+c2h(k-1))*(c1f(k)*MUT(i,j)+c2f(k))) )
          c =   -cqw(i,k,j)*cofs*rdn(k)*rdnw(k  )*c2a(i,k,j  )/((c1h(k)*MUT(i,j)+c2h(k))*(c1f(k+1)*MUT(i,j)+c2f(k+1)))
          alpha(i,k,j) = 1./(b-a(i,k,j)*gamma(i,k-1,j))
          gamma(i,k,j) = c*alpha(i,k,j)
        ENDDO
        k=kde
        b = 1.+2.*cofs*rdnw(kde-1)**2*c2a(i,kde-1,j)/((c1h(k-1)*MUT(i,j)+c2h(k-1))*(c1f(k)*MUT(i,j)+c2f(k)))
        c = 0.
        alpha(i,kde,j) = 1./(b-a(i,kde,j)*gamma(i,kde-1,j))
        gamma(i,kde,j) = c*alpha(i,kde,j)
      ENDDO
      ENDDO
      RETURN
#endif
