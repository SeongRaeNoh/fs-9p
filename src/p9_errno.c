/*
 * p9_errno.c - Linux errno values (9P2000.L Rlerror) to QNX errno values.
 *
 * Linux numbers: Linux UAPI headers asm-generic/errno-base.h and asm-generic/errno.h (public).
 * QNX numbers: taken by name from the QNX <errno.h> at compile time; a Linux code whose name QNX
 * does not define maps to EIO. Linux EOPNOTSUPP (95) is also Linux ENOTSUP; it maps to QNX ENOTSUP.
 * Generated once by a script from the list of names; edit by hand.
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <errno.h>
#include "p9_errno.h"

#define M(l, n) { l, n, #n }

const struct p9_errno_entry p9_errno_table[] = {
    M(1, EPERM),
    M(2, ENOENT),
    M(3, ESRCH),
    M(4, EINTR),
    M(5, EIO),
    M(6, ENXIO),
    M(7, E2BIG),
    M(8, ENOEXEC),
    M(9, EBADF),
    M(10, ECHILD),
    M(11, EAGAIN),
    M(12, ENOMEM),
    M(13, EACCES),
    M(14, EFAULT),
#ifdef ENOTBLK
    M(15, ENOTBLK),
#endif
    M(16, EBUSY),
    M(17, EEXIST),
    M(18, EXDEV),
    M(19, ENODEV),
    M(20, ENOTDIR),
    M(21, EISDIR),
    M(22, EINVAL),
    M(23, ENFILE),
    M(24, EMFILE),
    M(25, ENOTTY),
    M(26, ETXTBSY),
    M(27, EFBIG),
    M(28, ENOSPC),
    M(29, ESPIPE),
    M(30, EROFS),
    M(31, EMLINK),
    M(32, EPIPE),
    M(33, EDOM),
    M(34, ERANGE),
#ifdef EDEADLK
    M(35, EDEADLK),
#endif
#ifdef ENAMETOOLONG
    M(36, ENAMETOOLONG),
#endif
#ifdef ENOLCK
    M(37, ENOLCK),
#endif
#ifdef ENOSYS
    M(38, ENOSYS),
#endif
#ifdef ENOTEMPTY
    M(39, ENOTEMPTY),
#endif
#ifdef ELOOP
    M(40, ELOOP),
#endif
#ifdef ENOMSG
    M(42, ENOMSG),
#endif
#ifdef EIDRM
    M(43, EIDRM),
#endif
#ifdef ECHRNG
    M(44, ECHRNG),
#endif
#ifdef EL2NSYNC
    M(45, EL2NSYNC),
#endif
#ifdef EL3HLT
    M(46, EL3HLT),
#endif
#ifdef EL3RST
    M(47, EL3RST),
#endif
#ifdef ELNRNG
    M(48, ELNRNG),
#endif
#ifdef EUNATCH
    M(49, EUNATCH),
#endif
#ifdef ENOCSI
    M(50, ENOCSI),
#endif
#ifdef EL2HLT
    M(51, EL2HLT),
#endif
#ifdef EBADE
    M(52, EBADE),
#endif
#ifdef EBADR
    M(53, EBADR),
#endif
#ifdef EXFULL
    M(54, EXFULL),
#endif
#ifdef ENOANO
    M(55, ENOANO),
#endif
#ifdef EBADRQC
    M(56, EBADRQC),
#endif
#ifdef EBADSLT
    M(57, EBADSLT),
#endif
#ifdef EBFONT
    M(59, EBFONT),
#endif
#ifdef ENOSTR
    M(60, ENOSTR),
#endif
#ifdef ENODATA
    M(61, ENODATA),
#endif
#ifdef ETIME
    M(62, ETIME),
#endif
#ifdef ENOSR
    M(63, ENOSR),
#endif
#ifdef ENONET
    M(64, ENONET),
#endif
#ifdef ENOPKG
    M(65, ENOPKG),
#endif
#ifdef EREMOTE
    M(66, EREMOTE),
#endif
#ifdef ENOLINK
    M(67, ENOLINK),
#endif
#ifdef EADV
    M(68, EADV),
#endif
#ifdef ESRMNT
    M(69, ESRMNT),
#endif
#ifdef ECOMM
    M(70, ECOMM),
#endif
#ifdef EPROTO
    M(71, EPROTO),
#endif
#ifdef EMULTIHOP
    M(72, EMULTIHOP),
#endif
#ifdef EDOTDOT
    M(73, EDOTDOT),
#endif
#ifdef EBADMSG
    M(74, EBADMSG),
#endif
#ifdef EOVERFLOW
    M(75, EOVERFLOW),
#endif
#ifdef ENOTUNIQ
    M(76, ENOTUNIQ),
#endif
#ifdef EBADFD
    M(77, EBADFD),
#endif
#ifdef EREMCHG
    M(78, EREMCHG),
#endif
#ifdef ELIBACC
    M(79, ELIBACC),
#endif
#ifdef ELIBBAD
    M(80, ELIBBAD),
#endif
#ifdef ELIBSCN
    M(81, ELIBSCN),
#endif
#ifdef ELIBMAX
    M(82, ELIBMAX),
#endif
#ifdef ELIBEXEC
    M(83, ELIBEXEC),
#endif
#ifdef EILSEQ
    M(84, EILSEQ),
#endif
#ifdef ERESTART
    M(85, ERESTART),
#endif
#ifdef ESTRPIPE
    M(86, ESTRPIPE),
#endif
#ifdef EUSERS
    M(87, EUSERS),
#endif
#ifdef ENOTSOCK
    M(88, ENOTSOCK),
#endif
#ifdef EDESTADDRREQ
    M(89, EDESTADDRREQ),
#endif
#ifdef EMSGSIZE
    M(90, EMSGSIZE),
#endif
#ifdef EPROTOTYPE
    M(91, EPROTOTYPE),
#endif
#ifdef ENOPROTOOPT
    M(92, ENOPROTOOPT),
#endif
#ifdef EPROTONOSUPPORT
    M(93, EPROTONOSUPPORT),
#endif
#ifdef ESOCKTNOSUPPORT
    M(94, ESOCKTNOSUPPORT),
#endif
#if defined(ENOTSUP)
    { 95, ENOTSUP, "ENOTSUP" },
#elif defined(EOPNOTSUPP)
    M(95, EOPNOTSUPP),
#endif
#ifdef EPFNOSUPPORT
    M(96, EPFNOSUPPORT),
#endif
#ifdef EAFNOSUPPORT
    M(97, EAFNOSUPPORT),
#endif
#ifdef EADDRINUSE
    M(98, EADDRINUSE),
#endif
#ifdef EADDRNOTAVAIL
    M(99, EADDRNOTAVAIL),
#endif
#ifdef ENETDOWN
    M(100, ENETDOWN),
#endif
#ifdef ENETUNREACH
    M(101, ENETUNREACH),
#endif
#ifdef ENETRESET
    M(102, ENETRESET),
#endif
#ifdef ECONNABORTED
    M(103, ECONNABORTED),
#endif
#ifdef ECONNRESET
    M(104, ECONNRESET),
#endif
#ifdef ENOBUFS
    M(105, ENOBUFS),
#endif
#ifdef EISCONN
    M(106, EISCONN),
#endif
#ifdef ENOTCONN
    M(107, ENOTCONN),
#endif
#ifdef ESHUTDOWN
    M(108, ESHUTDOWN),
#endif
#ifdef ETOOMANYREFS
    M(109, ETOOMANYREFS),
#endif
#ifdef ETIMEDOUT
    M(110, ETIMEDOUT),
#endif
#ifdef ECONNREFUSED
    M(111, ECONNREFUSED),
#endif
#ifdef EHOSTDOWN
    M(112, EHOSTDOWN),
#endif
#ifdef EHOSTUNREACH
    M(113, EHOSTUNREACH),
#endif
#ifdef EALREADY
    M(114, EALREADY),
#endif
#ifdef EINPROGRESS
    M(115, EINPROGRESS),
#endif
#ifdef ESTALE
    M(116, ESTALE),
#endif
#ifdef EUCLEAN
    M(117, EUCLEAN),
#endif
#ifdef ENOTNAM
    M(118, ENOTNAM),
#endif
#ifdef ENAVAIL
    M(119, ENAVAIL),
#endif
#ifdef EISNAM
    M(120, EISNAM),
#endif
#ifdef EREMOTEIO
    M(121, EREMOTEIO),
#endif
#ifdef EDQUOT
    M(122, EDQUOT),
#endif
#ifdef ENOMEDIUM
    M(123, ENOMEDIUM),
#endif
#ifdef EMEDIUMTYPE
    M(124, EMEDIUMTYPE),
#endif
#ifdef ECANCELED
    M(125, ECANCELED),
#endif
#ifdef ENOKEY
    M(126, ENOKEY),
#endif
#ifdef EKEYEXPIRED
    M(127, EKEYEXPIRED),
#endif
#ifdef EKEYREJECTED
    M(129, EKEYREJECTED),
#endif
#ifdef EKEYREVOKED
    M(128, EKEYREVOKED),
#endif
#ifdef EOWNERDEAD
    M(130, EOWNERDEAD),
#endif
#ifdef ENOTRECOVERABLE
    M(131, ENOTRECOVERABLE),
#endif
#ifdef ERFKILL
    M(132, ERFKILL),
#endif
#ifdef EHWPOISON
    M(133, EHWPOISON),
#endif
};

const unsigned p9_errno_table_len = sizeof p9_errno_table / sizeof p9_errno_table[0];

int p9_errno_to_qnx(unsigned linux_errno)
{
    for (unsigned i = 0; i < p9_errno_table_len; i++)
        if ((unsigned)p9_errno_table[i].linux_errno == linux_errno) return p9_errno_table[i].qnx_errno;
    return EIO;
}
