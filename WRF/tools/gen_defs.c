#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
# include <strings.h>
#endif

#include "protos.h"
#include "registry.h"
#include "data.h"

enum sw_ranges { COLON_RANGE , ARGADJ , GRIDREF } ;
enum sw_pointdecl { POINTERDECL , NOPOINTERDECL } ;

int
gen_state_struct ( char * dirname )
{
  FILE * fp ;
  char  fname[NAMELEN] ;
  char * fn = "state_struct.inc" ;

  strcpy( fname, fn ) ;
  if ( strlen(dirname) > 0 ) { sprintf(fname,"%s/%s",dirname,fn) ; }
  if ((fp = fopen( fname , "w" )) == NULL ) return(1) ;
  print_warning(fp,fname) ;
  gen_decls ( fp , &Domain , COLON_RANGE , POINTERDECL , FIELD | RCONFIG | FOURD , DRIVER_LAYER ) ;
  close_the_file( fp ) ;
  return(0) ;
}

int
gen_state_subtypes ( char * dirname )
{
  FILE * fp ;
  char  fname[NAMELEN] ;
  char * fn = "state_subtypes.inc" ;

  strcpy( fname, fn ) ;
  if ( strlen(dirname) > 0 ) { sprintf(fname,"%s/%s",dirname,fn) ; }

  if ((fp = fopen( fname , "w" )) == NULL ) return(1) ;
  print_warning(fp,fname) ;
  gen_state_subtypes1( fp , &Domain , COLON_RANGE , POINTERDECL , FIELD | RCONFIG | FOURD ) ;
  close_the_file(fp) ;
  return(0) ;
}

int
gen_dummy_decls ( char * dn )
{
  FILE * fp ;
  char fname[NAMELEN] ;
  char * fn = "dummy_decl.inc" ;

  if ( dn == NULL ) return(1) ;
  if ( strlen(dn) > 0 ) { sprintf(fname,"%s/%s",dn,fn) ; }
  else                  { sprintf(fname,"%s",fn) ; }
  if ((fp = fopen( fname , "w" )) != NULL ) {
    print_warning(fp,fname) ;
    gen_decls ( fp, &Domain , GRIDREF , NOPOINTERDECL , FIELD | FOURD , MEDIATION_LAYER ) ;
    fprintf(fp,"#undef COPY_IN\n") ;
    fprintf(fp,"#undef COPY_OUT\n") ;
    close_the_file( fp ) ;
  }
  return(0);
}

int
gen_dummy_decls_new ( char * dn )
{
  FILE * fp ;
  char fname[NAMELEN] ;
  char * fn = "dummy_new_decl.inc" ;

  if ( dn == NULL ) return(1) ;
  if ( strlen(dn) > 0 ) { sprintf(fname,"%s/%s",dn,fn) ; }
  else                  { sprintf(fname,"%s",fn) ; }
  if ((fp = fopen( fname , "w" )) != NULL ) {
    print_warning(fp,fname) ;
    gen_decls ( fp, &Domain , GRIDREF , NOPOINTERDECL , FOURD | FIELD | BDYONLY , MEDIATION_LAYER ) ;
    fprintf(fp,"#undef COPY_IN\n") ;
    fprintf(fp,"#undef COPY_OUT\n") ;
    close_the_file( fp ) ;
  }
  return(0);
}


/* ---------------------------------------------------------------------------
 * GPU port (plan.md P1.6, P0.9a item 2): persistent scratch pool.
 * With -DWRF_POOL every REAL i1 array of solve_em becomes a CONTIGUOUS
 * pointer onto module_gpu_scratch's gpu_pool (allocated once, zero-filled);
 * i1_assoc.inc reserves the pool and associates the pointers with the same
 * bounds as the original automatic arrays.  Non-REAL i1 arrays stay automatic.
 * ------------------------------------------------------------------------- */

#define POOL_MAX 400
static char pool_name[POOL_MAX][NAMELEN] ;
static char pool_bounds[POOL_MAX][NAMELEN*4] ;
static int  pool_rank[POOL_MAX] ;
static int  pool_old[POOL_MAX] ;      /* 1: declared under #ifndef NO_I1_OLD */
static int  pool_n = 0 ;

/* ",DIMENSION(a:b,c:d,num_x)" -> "a:b,c:d,1:num_x", returns rank */
static int
pool_bounds_from_dimspec( char * dimspec, char * out )
{
  char * s ; char buf[NAMELEN*4] ; char * tok ; int rank = 0 ; size_t n ;
  s = strstr( dimspec, "DIMENSION(" ) ;
  if ( s == NULL ) return 0 ;
  strcpy( buf, s + strlen("DIMENSION(") ) ;
  n = strlen(buf) ;
  if ( n > 0 && buf[n-1] == ')' ) buf[n-1] = '\0' ;
  out[0] = '\0' ;
  for ( tok = strtok( buf, "," ) ; tok != NULL ; tok = strtok( NULL, "," ) ) {
    if ( rank > 0 ) strcat( out, "," ) ;
    if ( strchr( tok, ':' ) == NULL ) strcat( out, "1:" ) ;
    strcat( out, tok ) ;
    rank++ ;
  }
  return rank ;
}

static void
pool_add( char * name, char * dimspec, int is_old )
{
  if ( pool_n >= POOL_MAX ) { fprintf(stderr,"gen_i1_decls: too many i1 arrays for the pool\n") ; exit(1) ; }
  strcpy( pool_name[pool_n], name ) ;
  pool_rank[pool_n] = pool_bounds_from_dimspec( dimspec, pool_bounds[pool_n] ) ;
  pool_old[pool_n] = is_old ;
  pool_n++ ;
}

static void
pool_size_lines( FILE * fp, int i, char * acc )
{
  char buf[NAMELEN*4] ; char * tok ; char * c ;
  strcpy( buf, pool_bounds[i] ) ;
  fprintf(fp,"  wrf_pool_s = 1_8\n") ;
  for ( tok = strtok( buf, "," ) ; tok != NULL ; tok = strtok( NULL, "," ) ) {
    c = strchr( tok, ':' ) ; *c = '\0' ;
    fprintf(fp,"  wrf_pool_s = wrf_pool_s*INT(MAX(0,(%s)-(%s)+1),8)\n", c+1, tok ) ;
  }
  if ( acc != NULL ) fprintf(fp,"  %s = %s + wrf_pool_round(wrf_pool_s)\n", acc, acc ) ;
}

static int
gen_i1_pool_files( char * dn )
{
  FILE * fp ; char fname[NAMELEN] ; int i, r ;
  char * fn = "i1_assoc.inc" ;
  if ( strlen(dn) > 0 ) { sprintf(fname,"%s/%s",dn,fn) ; }
  else                  { sprintf(fname,"%s",fn) ; }
  if ((fp = fopen( fname , "w" )) == NULL ) return(1) ;
  print_warning(fp,fname) ;
  fprintf(fp,"#ifdef WRF_POOL\n") ;
  fprintf(fp,"! size of the pool for this domain\n") ;
  fprintf(fp,"  wrf_pool_n = 0_8\n") ;
  for ( i = 0 ; i < pool_n ; i++ ) {
    if ( pool_old[i] ) fprintf(fp,"#ifndef NO_I1_OLD\n") ;
    pool_size_lines( fp, i, "wrf_pool_n" ) ;
    if ( pool_old[i] ) fprintf(fp,"#endif\n") ;
  }
  fprintf(fp,"  CALL gpu_scratch_reserve( wrf_pool_n )\n") ;
  fprintf(fp,"! associate each i1 array with its part of the pool\n") ;
  fprintf(fp,"  wrf_pool_o = 0_8\n") ;
  for ( i = 0 ; i < pool_n ; i++ ) {
    if ( pool_old[i] ) fprintf(fp,"#ifndef NO_I1_OLD\n") ;
    pool_size_lines( fp, i, NULL ) ;
    fprintf(fp,"  %s(%s) => gpu_pool(wrf_pool_o+1:wrf_pool_o+wrf_pool_s)\n", pool_name[i], pool_bounds[i] ) ;
    fprintf(fp,"  wrf_pool_o = wrf_pool_o + wrf_pool_round(wrf_pool_s)\n") ;
    if ( pool_old[i] ) fprintf(fp,"#endif\n") ;
  }
  fprintf(fp,"#endif\n") ;
  close_the_file( fp ) ;
  return(0) ;
}

static void
pool_decl( FILE * fp, int i, char * type )
{
  int r ;
  if ( pool_old[i] ) fprintf(fp,"#ifndef NO_I1_OLD\n") ;
  fprintf(fp,"%-10s,POINTER,CONTIGUOUS :: %s(", type, pool_name[i] ) ;
  for ( r = 0 ; r < pool_rank[i] ; r++ ) fprintf(fp,"%s:", (r>0)?",":"" ) ;
  fprintf(fp,")\n") ;
  if ( pool_old[i] ) fprintf(fp,"#endif\n") ;
}

int
gen_i1_decls ( char * dn )
{
  FILE * fp ;
  char  fname[NAMELEN], post[NAMELEN] ;
  char * fn = "i1_decl.inc" ;
  char * dimspec ;
  node_t * p ; 
  int i, tag ;

  if ( dn == NULL ) return(1) ;
  if ( strlen(dn) > 0 ) { sprintf(fname,"%s/%s",dn,fn) ; }
  else                  { sprintf(fname,"%s",fn) ; }
  if ((fp = fopen( fname , "w" )) != NULL ) {
    print_warning(fp,fname) ;

    /* pooled declarations (REAL arrays) and automatic ones (everything else) */
    fprintf(fp,"#ifdef WRF_POOL\n") ;
    pool_n = 0 ;
    for ( p = Domain.fields ; p != NULL ; p = p->next ) {
      if ( ! ( p->node_kind & I1 ) ) continue ;
      for ( tag = 1 ; tag <= p->ntl ; tag++ ) {
        strcpy(fname,field_name(t4,p,(p->ntl>1)?tag:0)) ;
        sprintf(post,")") ;
        dimspec=dimension_with_ranges( "grid%",",DIMENSION(",-1,t2,p,post,"" ) ;
        if ( !strcmp( dimspec, "" ) || strcmp( field_type( t1, p ), "real" ) ) {
          fprintf(fp, "%-10s%-20s%-10s :: %s\n", field_type( t1, p ), dimspec, "", fname ) ;
        } else {
          pool_add( fname, dimspec, 0 ) ;
          pool_decl( fp, pool_n-1, field_type( t1, p ) ) ;
        }
      }
    }
    for ( p = FourD ; p != NULL ; p = p->next )
    {
      if ( p->node_kind & FOURD && p->has_scalar_array_tendencies )
      {
        sprintf(post,",num_%s)",p->name) ;
        dimspec=dimension_with_ranges( "grid%",",DIMENSION(",-1,t2,p,post,"" ) ;
        sprintf(fname,"%s_tend",p->name) ;
        pool_add( fname, dimspec, 0 ) ;
        pool_decl( fp, pool_n-1, field_type( t1, p ) ) ;
        sprintf(fname,"%s_old",p->name) ;
        pool_add( fname, dimspec, 1 ) ;
        pool_decl( fp, pool_n-1, field_type( t1, p ) ) ;
      }
    }
    fprintf(fp,"INTEGER(8) :: wrf_pool_n, wrf_pool_o, wrf_pool_s\n") ;
    fprintf(fp,"#else\n") ;
    gen_decls ( fp , &Domain , GRIDREF , NOPOINTERDECL , I1 , MEDIATION_LAYER ) ;

    /* now generate tendencies for 4d vars if specified  */
    for ( p = FourD ; p != NULL ; p = p->next )
    {
      if ( p->node_kind & FOURD && p->has_scalar_array_tendencies )
      {
        sprintf(fname,"%s_tend",p->name) ;
        sprintf(post,",num_%s)",p->name) ;
        dimspec=dimension_with_ranges( "grid%",",DIMENSION(",-1,t2,p,post,"" ) ;
        /*          type dim pdecl   name */
        fprintf(fp, "%-10s%-20s%-10s :: %s\n",
                    field_type( t1, p ) ,
                    dimspec ,
                    "" ,
                    fname ) ;
        sprintf(fname,"%s_old",p->name) ;
        sprintf(post,",num_%s)",p->name) ;
        dimspec=dimension_with_ranges( "grid%",",DIMENSION(",-1,t2,p,post,"" ) ;
        /*          type dim pdecl   name */
        fprintf(fp, "#ifndef NO_I1_OLD\n") ;
        fprintf(fp, "%-10s%-20s%-10s :: %s\n",
                    field_type( t1, p ) ,
                    dimspec ,
                    "" ,
                    fname ) ;
        fprintf(fp, "#endif\n") ;
      }
    }
    fprintf(fp,"#endif\n") ;
    close_the_file( fp ) ;
    if ( gen_i1_pool_files( dn ) ) return(1) ;
  }
  return(0) ;
}

int
gen_decls ( FILE * fp , node_t * node , int sw_ranges, int sw_point , int mask , int layer )
{
  node_t * p ; 
  int tag, ipass ;
  char fname[NAMELEN], post[NAMELEN] ;
  char * dimspec ;
  int bdyonly = 0 ;

  if ( node == NULL ) return(1) ;

  bdyonly = mask & BDYONLY ;

/* make two passes; the first is for scalars, second for arrays.                     */
/* do it this way so that the scalars get declared first (some compilers complain    */
/* if a scalar is used to declare an array before it's declared)                     */

  for ( ipass = 0 ; ipass < 2 ; ipass++ ) 
  {
  for ( p = node->fields ; p != NULL ; p = p->next )
  {
    if ( p->node_kind & mask )
    {
      /* add an extra dimension to the 4d arrays.                                       */
      /* note the call to dimension_with_colons, below, does this by itself             */
      /* but dimension_with_ranges needs help (since the last arg is not just a colon)  */

      if       ( p->node_kind & FOURD ) { 
          sprintf(post,",num_%s)",field_name(t4,p,0)) ;
      } else { 
          sprintf(post,")") ;
      }

      for ( tag = 1 ; tag <= p->ntl ; tag++ ) 
      {
        strcpy(fname,field_name(t4,p,(p->ntl>1)?tag:0)) ;

        if ( ! p->boundary_array || ! sw_new_bdys ) {
          switch ( sw_ranges )
          {
            case COLON_RANGE :
              dimspec=dimension_with_colons( ",DIMENSION(",t2,p,")" ) ; break ;
            case GRIDREF :
              dimspec=dimension_with_ranges( "grid%",",DIMENSION(",-1,t2,p,post,"" ) ; break ;
            case ARGADJ :
              dimspec=dimension_with_ranges( "",",DIMENSION(",-1,t2,p,post,"" ) ; break ;
          }
        } else {
          dimspec="dummy" ; /* allow fall through on next tests. dimension with ranges will be called again anyway for bdy arrays */
        }

        if ( !strcmp( dimspec, "" ) && ipass == 1 ) continue ; /* short circuit scalars on 2nd pass  */
        if (  strcmp( dimspec, "" ) && ipass == 0 ) continue ; /* short circuit arrays on 2nd pass   */
        if ( bdyonly && p->node_kind & FIELD && ! p->boundary_array )  continue ;  /* short circuit all fields except bdy arrrays */

        if ( p->boundary_array && sw_new_bdys ) {
          if ( layer == DRIVER_LAYER || associated_with_4d_array(p) ) {
          int bdy ;
          for ( bdy = 1; bdy <=4 ; bdy++ ) {
            switch ( sw_ranges )
            {
              case COLON_RANGE :
                dimspec=dimension_with_colons( ",DIMENSION(",t2,p,")" ) ; break ;
              case GRIDREF :
                dimspec=dimension_with_ranges( "grid%",",DIMENSION(",bdy,t2,p,post,"" ) ; break ;
              case ARGADJ :
                dimspec=dimension_with_ranges( "",",DIMENSION(",bdy,t2,p,post,"" ) ; break ;
            }
            /*          type dim pdecl   name */
            fprintf(fp, "%-10s%-20s%-10s :: %s%s\n",
                        field_type( t1, p ) ,
                        dimspec ,
                        (sw_point==POINTERDECL)?declare_array_as_pointer(t3,p):"" ,
                        fname, bdy_indicator( bdy )  ) ;
          }
          }
        } else {
          switch ( sw_ranges )
          {
            case COLON_RANGE :
              dimspec=dimension_with_colons( ",DIMENSION(",t2,p,")" ) ; break ;
            case GRIDREF :
              dimspec=dimension_with_ranges( "grid%",",DIMENSION(",-1,t2,p,post,"" ) ; break ;
            case ARGADJ :
              dimspec=dimension_with_ranges( "",",DIMENSION(",-1,t2,p,post,"" ) ; break ;
          }
          /*          type dim pdecl   name */
          fprintf(fp, "%-10s%-20s%-10s :: %s\n",
                      field_type( t1, p ) ,
                      dimspec ,
                      (sw_point==POINTERDECL)?declare_array_as_pointer(t3,p):"" ,
                      fname ) ;
        }
      }
    }
  }
  }
  return(0) ;
}

int
gen_state_subtypes1 ( FILE * fp , node_t * node , int sw_ranges , int sw_point , int mask )
{
  node_t * p ;
  int i ;
  int new;
  char TypeName [NAMELEN] ;
  char tempname [NAMELEN] ;
  if ( node == NULL ) return(1) ;
  for ( p = node->fields ; p != NULL ; p = p->next )
  {
    if ( p->type != NULL )
      if ( p->type->type_type == DERIVED )
      {
        new = 1 ;    /* determine if this is a new type -ajb */
        strcpy( tempname, p->type->name ) ;
        for ( i = 0 ; i < get_num_typedefs() ; i++ )        
        { 
          strcpy( TypeName, get_typename_i(i) ) ;
          if ( ! strcmp( TypeName, tempname ) ) new = 0 ;
        }

        if ( new )   /* add this type to the history and generate declarations -ajb */
        {
          add_typedef_name ( tempname ) ;
          gen_state_subtypes1 ( fp , p->type , sw_ranges , sw_point , mask ) ;
          fprintf(fp,"TYPE %s\n",p->type->name) ;
          gen_decls ( fp , p->type , sw_ranges , sw_point , mask , DRIVER_LAYER ) ;
          fprintf(fp,"END TYPE %s\n",p->type->name) ;
        }
      }
  }
  return(0) ;
}

/* old version of gen_state_subtypes1 -ajb */
/*
int
gen_state_subtypes1 ( FILE * fp , node_t * node , int sw_ranges , int sw_point , int mask )
{
  node_t * p ;
  int tag ;
  if ( node == NULL ) return(1) ;
  for ( p = node->fields ; p != NULL ; p = p->next )
  {
    if ( p->type != NULL )
      if ( p->type->type_type == DERIVED )
      {
        gen_state_subtypes1 ( fp , p->type , sw_ranges , sw_point , mask ) ;
        fprintf(fp,"TYPE %s\n",p->type->name) ;
        gen_decls ( fp , "", p->type , sw_ranges , sw_point , mask , DRIVER_LAYER ) ;
        fprintf(fp,"END TYPE %s\n",p->type->name) ;
      }
  }
  return(0) ;
}
*/
