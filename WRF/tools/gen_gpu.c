/*
   gen_gpu.c -- update lists for the WRF GPU port (plan.md P1.3).

   Writes into inc/:

     gpu_upd_dev_all.inc    !$omp target update to(...)   of every field allocs.inc allocates
     gpu_upd_host_all.inc   !$omp target update from(...) of the same fields
     gpu_upd_dev_bdy.inc    !$omp target update to(...)   of the boundary arrays only

   The walk over the fields is the one of gen_alloc2 (gen_allocs.c): arrays and
   boundary arrays of kind FIELD or FOURD, every time level, the 4D boundary
   arrays (use _4d_bdy_array_), the four boundary arrays of each boundary field
   (bdy_indicator), and the components of derived types.  Each non-boundary
   field is guarded by the same in_use_for_config test that allocs.inc uses, so
   fields allocated as (1,1,1) dummies are not moved.  Boundary arrays are
   allocated unconditionally (IF(.TRUE.) in allocs.inc) and are moved
   unconditionally.  Everything is inside #ifdef WRF_GPU; the files are included
   by WRF/frame/module_gpu_updates.F.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
# include <strings.h>
#endif

#include "protos.h"
#include "registry.h"
#include "data.h"

#define GPU_UPD_ALL 0
#define GPU_UPD_BDY 1

static int gen_gpu1 ( char * dirname , char * fn , char * dir , int which ) ;
static int gen_gpu2 ( FILE * fp , char * structname , char * structname2 , node_t * node , char * dir , int which ) ;

int
gen_gpu ( char * dirname )
{
  if ( gen_gpu1( dirname , "gpu_upd_dev_all.inc"  , "to"   , GPU_UPD_ALL ) ) return(1) ;
  if ( gen_gpu1( dirname , "gpu_upd_host_all.inc" , "from" , GPU_UPD_ALL ) ) return(1) ;
  if ( gen_gpu1( dirname , "gpu_upd_dev_bdy.inc"  , "to"   , GPU_UPD_BDY ) ) return(1) ;
  return(0) ;
}

static int
gen_gpu1 ( char * dirname , char * fn , char * dir , int which )
{
  FILE * fp ;
  char fname[NAMELEN] ;

  if ( dirname == NULL ) return(1) ;
  if ( strlen(dirname) > 0 ) { sprintf(fname,"%s/%s",dirname,fn) ; }
  else                       { sprintf(fname,"%s",fn) ; }
  if ((fp = fopen( fname , "w" )) == NULL ) return(1) ;
  print_warning(fp,fname) ;
  fprintf(fp,"#ifdef WRF_GPU\n") ;
  gen_gpu2( fp , "grid%" , NULL , &Domain , dir , which ) ;
  fprintf(fp,"#endif\n") ;
  close_the_file( fp ) ;
  return(0) ;
}

static int
gen_gpu2 ( FILE * fp , char * structname , char * structname2 , node_t * node , char * dir , int which )
{
  node_t * p ;
  int tag , bdy ;
  char fname[NAMELEN] , fname2[NAMELEN] ;
  char x[NAMELEN] , x2[NAMELEN] ;

  if ( node == NULL ) return(1) ;

  for ( p = node->fields ; p != NULL ; p = p->next )
  {
    /* the same selection as gen_alloc2 */
    if ( (p->ndims > 0 || p->boundary_array) && (
          (p->node_kind & FIELD) ||
          (p->node_kind & FOURD) )
       )
    {
      for ( tag = 1 ; tag <= p->ntl ; tag++ )
      {
        if ( !strcmp ( p->use , "_4d_bdy_array_") ) {
          strcpy(fname,p->name) ;
        } else {
          strcpy(fname,field_name(t4,p,(p->ntl>1)?tag:0)) ;
        }
        if ( structname2 != NULL ) {
          sprintf(fname2,"%s%s",structname2,fname) ;
        } else {
          strcpy(fname2,fname) ;
        }

        if ( p->boundary_array ) {
          /* allocated unconditionally by allocs.inc */
          if ( sw_new_bdys ) {
            for ( bdy = 1 ; bdy <= 4 ; bdy++ ) {
              fprintf(fp,"!$omp target update %s(%s%s%s)\n", dir, structname, fname, bdy_indicator(bdy) ) ;
            }
          } else {
            fprintf(fp,"!$omp target update %s(%s%s)\n", dir, structname, fname ) ;
          }
        } else if ( which == GPU_UPD_ALL ) {
          fprintf(fp,"IF (in_use_for_config(grid%%id,'%s')) THEN\n", fname2 ) ;
          fprintf(fp,"!$omp target update %s(%s%s)\n", dir, structname, fname ) ;
          fprintf(fp,"ENDIF\n") ;
        }
      }
    }
    if ( p->type != NULL )
    {
      if ( p->type->type_type == DERIVED )
      {
        sprintf(x,"%s%s%%",structname,p->name ) ;
        sprintf(x2,"%s%%",p->name ) ;
        gen_gpu2( fp , x , x2 , p->type , dir , which ) ;
      }
    }
  }
  return(0) ;
}
