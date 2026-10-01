/*
   gen_gpu.c -- update lists for the WRF GPU port (plan.md P1.3).

   Writes into inc/:

     gpu_upd_dev_all.inc    host -> device update of every field allocs.inc allocates
     gpu_upd_host_all.inc   device -> host update of the same fields
     gpu_upd_dev_bdy.inc    host -> device update of the boundary arrays only

   Each update is a call of the by-address mapping routines of
   WRF/frame/module_gpu_map.F (gpu_map_call below, also used by gen_allocs.c
   for the enter/exit data of P1.2):
     CALL gpu_map_r(grid%u_2, SIZE(grid%u_2,KIND=8), GPU_UPD_TO)

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

/* One call of the by-address mapping routines (WRF/frame/module_gpu_map.F)
   for the field structname//fname//suffix of node p.  guard: a Fortran
   condition, or "" for none.  op: GPU_MAP_ENTER, GPU_MAP_EXIT, GPU_UPD_TO or
   GPU_UPD_FROM.  A type without a mapping routine gets a warning and no call. */
int
gpu_map_call ( FILE * fp , char * guard , char * structname , char * fname , char * suffix , node_t * p , char * op )
{
  char t ;
  if ( p == NULL || p->type == NULL ) return(1) ;
  if      ( !strcmp( p->type->name , "real" ) )            t = 'r' ;
  else if ( !strcmp( p->type->name , "doubleprecision" ) ) t = 'd' ;
  else if ( !strcmp( p->type->name , "integer" ) )         t = 'i' ;
  else if ( !strcmp( p->type->name , "logical" ) )         t = 'l' ;
  else {
    fprintf(stderr,"gen_gpu: WARNING no device mapping for %s%s%s (type %s)\n",
            structname, fname, suffix, p->type->name) ;
    return(1) ;
  }
  if ( guard != NULL && strlen(guard) > 0 ) fprintf(fp,"  IF (%s) &\n", guard) ;
  fprintf(fp,"  CALL gpu_map_%c(%s%s%s, &\n    SIZE(%s%s%s,KIND=8), %s)\n",
          t, structname, fname, suffix, structname, fname, suffix, op) ;
  return(0) ;
}

int
gen_gpu ( char * dirname )
{
  if ( gen_gpu1( dirname , "gpu_upd_dev_all.inc"  , "GPU_UPD_TO"   , GPU_UPD_ALL ) ) return(1) ;
  if ( gen_gpu1( dirname , "gpu_upd_host_all.inc" , "GPU_UPD_FROM" , GPU_UPD_ALL ) ) return(1) ;
  if ( gen_gpu1( dirname , "gpu_upd_dev_bdy.inc"  , "GPU_UPD_TO"   , GPU_UPD_BDY ) ) return(1) ;
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
              gpu_map_call( fp , "" , structname , fname , bdy_indicator(bdy) , p , dir ) ;
            }
          } else {
            gpu_map_call( fp , "" , structname , fname , "" , p , dir ) ;
          }
        } else if ( which == GPU_UPD_ALL ) {
          fprintf(fp,"IF (in_use_for_config(grid%%id,'%s')) THEN\n", fname2 ) ;
          gpu_map_call( fp , "" , structname , fname , "" , p , dir ) ;
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
