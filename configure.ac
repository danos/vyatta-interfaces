# Process this file with autoconf to produce a configure script.
AC_PREREQ(2.59)
AC_INIT([vyatta-interfaces], [0.0], [support@brocade.com])

AC_CONFIG_AUX_DIR([config])
AM_INIT_AUTOMAKE([gnu no-dist-gzip dist-bzip2 subdir-objects])
AC_PREFIX_DEFAULT([/opt/vyatta])

AC_CONFIG_FILES(
  [Makefile tests/Makefile])

AC_PROG_CC
AC_PROG_CXX
AM_PROG_AS
AM_PROG_CC_C_O
AC_PATH_PROG(PERL, perl)
AC_OUTPUT
