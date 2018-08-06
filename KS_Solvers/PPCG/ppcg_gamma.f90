!
SUBROUTINE ppcg_gamma( h_psi, s_psi, overlap, precondition, &
                 npwx, npw, nbnd, psi, e, btype, &
                 ethr, maxter, notconv, avg_iter, sbsize, rr_step, scf_iter)
  !
  !----------------------------------------------------------------------------
  !
  ! E.V. Ignore btype, use ethr as threshold on subspace residual subspace
  ! SdG  restore btype use in the eigenvalue locking procedure
  !
  USE ppcg_param,         ONLY : DP, stdout
  USE mp,                 ONLY : mp_bcast, mp_root_sum, mp_sum
  USE mp_bands_util,      ONLY : intra_bgrp_comm, inter_bgrp_comm, root_bgrp_id, nbgrp, my_bgrp_id, &
                                 gstart
  USE descriptors,        ONLY : la_descriptor, descla_init, descla_local_dims
  USE parallel_toolkit,   ONLY : dsqmsym
  USE mp_diag,            ONLY : ortho_comm, np_ortho, me_ortho, ortho_comm_id, leg_ortho, &
                                 ortho_parent_comm, ortho_cntx, do_distr_diag_inside_bgrp
  !
  IMPLICIT NONE
  REAL (DP), PARAMETER :: ONE = 1.D0, ZERO = 0.D0
  COMPLEX (DP), PARAMETER :: C_ZERO = (0.D0,0.D0)
  !
  ! ... I/O variables
  !
  LOGICAL,      INTENT(IN)    :: overlap ! whether the eigenvalue problem is a generalized one or not
  INTEGER,      INTENT(IN)    :: npwx, npw, nbnd, maxter
  ! maximum number of PW for wavefunctions
  ! the number of plane waves
  ! number of bands
  ! maximum number of iterations
  COMPLEX (DP), INTENT(INOUT) :: psi(npwx,nbnd)
  INTEGER,      INTENT(IN)    :: btype(nbnd) ! one if the corresponding state has to be
                                             ! ...converged to full accuracy, zero otherwise (src/pwcom.f90)
  REAL (DP),    INTENT(INOUT) :: e(nbnd)
  REAL (DP),    INTENT(IN)    :: precondition(npw), ethr
  ! the diagonal preconditioner
  ! the convergence threshold for eigenvalues
  INTEGER,      INTENT(OUT)   :: notconv
  REAL(DP),     INTENT(OUT)   :: avg_iter
  ! number of notconverged elements
  ! average number of iterations in PPCG
  INTEGER,      INTENT(IN)   ::  sbsize, rr_step      ! sub-block size (num. of vectors in sub-blocks)
                                                      ! ...to be used in PPCG block splitting. by default, sbsize=1
                                                      ! run the Rayleigh Ritz procedure every rr_step
  INTEGER, INTENT(IN)         :: scf_iter             ! this variable should be removed in future version, used for timing purpose
  !
  ! ... local variables
  !
  COMPLEX(DP), ALLOCATABLE ::  hpsi(:,:), spsi(:,:), w(:,:), hw(:,:), sw(:,:), p(:,:), hp(:,:), sp(:,:)
  COMPLEX(DP)              ::  buffer(npwx,nbnd), buffer1(npwx,nbnd)
  REAL(DP), ALLOCATABLE    ::  K(:,:), K_store(:,:), M(:,:), M_store(:,:), work(:)
  INTEGER,  ALLOCATABLE    ::  iwork(:)
  REAL (DP)                ::  trG, trG1, trdif, trtol, lock_tol
  REAL (DP)                ::  coord_psi(sbsize,sbsize), coord_w(sbsize,sbsize), coord_p(sbsize,sbsize),  &
                               G(nbnd,nbnd), G1(nbnd, nbnd)
  REAL (DP)                ::  D(3*sbsize)
  INTEGER                  ::  nsb, sbsize_last, npw2, npwx2, sbsize3, dimp,                        &
                               l, i, j, iter, total_iter, ierr = 0, info = 0,                       &
                               col_idx(sbsize), lwork = -1, liwork = -1
  INTEGER                  ::  nact, nact_old, act_idx(nbnd), idx(nbnd)
                               ! number of active columns
                               ! number of active columns on previous iteration
                               ! indices of active columns
                               ! auxiliary indices
  INTEGER                  ::  n_start, n_end, my_n ! auxiliary indices for band group parallelization
  INTEGER                  ::  print_info     ! If > 0 then iteration information is printed
  REAL(DP), EXTERNAL :: DLANGE, DDOT

  EXTERNAL h_psi, s_psi
    ! h_psi(npwx,npw,nvec,psi,hpsi)
    !     calculates H|psi>
    ! s_psi(npwx,npw,nvec,psi,spsi)
    !     calculates S|psi> (if needed)
    !     Vectors psi,hpsi,spsi are dimensioned (npwx,nvec)

  REAL (DP), ALLOCATABLE    ::  Gl(:,:)
  !
  TYPE(la_descriptor)  :: desc
  ! descriptor of the current distributed Gram matrix
  LOGICAL :: la_proc
  ! flag to distinguish procs involved in linear algebra
  INTEGER, ALLOCATABLE :: irc_ip( : )
  INTEGER, ALLOCATABLE :: nrc_ip( : )
  INTEGER, ALLOCATABLE :: rank_ip( :, : )
  ! matrix distribution descriptors
  LOGICAL :: force_repmat    ! = .TRUE. to force replication of the Gram matrices for Cholesky
                             ! Needed if the sizes of these  matrices become too small after locking

  REAL                          :: res_array(maxter)

  INTEGER, PARAMETER :: blocksz = 256 ! used to optimize some omp parallel do loops
  INTEGER :: nblock
  nblock = (npw -1) /blocksz + 1      ! used to optimize some omp parallel do loops

  res_array     = 0.0
  !
  CALL start_clock( 'ppcg_gamma' )
  !
  !  ... Initialization and validation
  !
  print_info = 0 ! 3
  sbsize3 = sbsize*3
  npw2    = npw*2
  npwx2   = npwx*2
  !
  nact      =  nbnd
  nact_old  =  nbnd
  lock_tol  =  SQRT( ethr )  ! 1.D-4*SQRT( ethr )  ! 1.0D-7
  trdif     =  -1.D0
  ! trdif is used for stopping. It equals either
  ! the difference of traces of psi'*hpsi on two consecutive
  ! itrations or -1.D0 when this difference is undefined
  ! (e.g., initial iteration or the iteration following RR)
  trG    =  0.D0
  trG1   =  0.D0
  ! trG and trG1 are use to evaluate the difference of traces
  ! of psi'*hpsi on two consecutive iterations
  iter      =  1
  force_repmat = .FALSE.
  !
  CALL allocate_all
  !
  ! ... Compute block residual w = hpsi - psi*(psi'hpsi) (psi is orthonormal on input)
  !
  !    set Im[ psi(G=0) ] -  needed for numerical stability
  call start_clock('ppcg:hpsi')
  IF ( gstart == 2 ) psi(1,1:nbnd) = CMPLX( DBLE( psi(1,1:nbnd) ), 0.D0, kind=DP)
  CALL h_psi( npwx, npw, nbnd, psi, hpsi )
  if (overlap) CALL s_psi( npwx, npw, nbnd, psi, spsi)
  avg_iter = 1.d0
  call stop_clock('ppcg:hpsi')
  !
  !     G = psi'hpsi
  call start_clock('ppcg:dgemm')
  call threaded_memset( G, ZERO, nbnd*nbnd ) ! G = ZERO
  CALL divide(inter_bgrp_comm,nbnd,n_start,n_end); my_n = n_end - n_start + 1; !write (*,*) nbnd,n_start,n_end
  if (n_start .le. n_end) &
  CALL DGEMM('T','N', nbnd, my_n, npw2, 2.D0, psi, npwx2, hpsi(1,n_start), npwx2, 0.D0, G(1,n_start), nbnd)
  IF ( gstart == 2 ) CALL DGER( nbnd, my_n, -1.D0, psi, npwx2, hpsi(1,n_start), npwx2, G(1,n_start), nbnd )
  CALL mp_sum( G, inter_bgrp_comm )
  !
  CALL mp_sum( G, intra_bgrp_comm )
  call stop_clock('ppcg:dgemm')
  !
  !    w = hpsi - spsi*G
  call start_clock('ppcg:dgemm')
  call threaded_assign( w, hpsi, npwx, nact, bgrp_root_only=.true. )
  CALL divide(inter_bgrp_comm,nbnd,n_start,n_end); my_n = n_end - n_start + 1; !write (*,*) nbnd,n_start,n_end
  if (overlap) then
     if (n_start .le. n_end) &
     CALL DGEMM('N','N',npw2, nbnd, my_n, -ONE, spsi(1,n_start), npwx2, G(n_start,1), nbnd, ONE, w, npwx2)
  else
     if (n_start .le. n_end) &
     CALL DGEMM('N','N',npw2, nbnd, my_n, -ONE,  psi(1,n_start), npwx2, G(n_start,1), nbnd, ONE, w, npwx2)
  end if
  CALL mp_sum( w, inter_bgrp_comm )
  call stop_clock('ppcg:dgemm')
  !
  !
  ! ... Lock converged eigenpairs (set up act_idx and nact and store current nact in nact_old)
  call start_clock('ppcg:lock')
  nact_old = nact;
  CALL lock_epairs(npw, nbnd, btype, w, npwx, lock_tol, nact, act_idx)
  call stop_clock('ppcg:lock')
  !
  ! ... Set up iteration parameters after locking
  CALL setup_param
  !
  G1(1:nact,1:nact) = G(act_idx(1:nact), act_idx(1:nact))
  trG = get_trace( G1, nbnd, nact )
  !
  ! Print initial info ...
  IF (print_info >= 1)  THEN
     WRITE(stdout, '("Ethr: ",1pD9.2,", npw: ", I10, ", nbnd: ", I10, " , "   &
                "maxter: ",I5, ", sbsize:  ", I10,", nsb: ", I10 ,", nact: ", I10, ", trtol: ", 1pD9.2 )')  &
                ethr, npw, nbnd, maxter, sbsize, nsb, nact, trtol
     IF (print_info == 3) THEN
        CALL print_rnrm
        WRITE(stdout,'("Res. norm:  ", 1pD9.2)') res_array(iter)
     END IF
     CALL flush( stdout )
  END IF
  !
  !---Begin the main loop
  !
  DO WHILE ( ((trdif > trtol) .OR. (trdif == -1.D0))  .AND. (iter <= maxter) .AND. (nact > 0) )
     !
     ! ... apply the diagonal preconditioner
     !
     !$omp parallel do collapse(2)
     DO j = 1, nact ; DO i=1,nblock
        w(1+(i-1)*blocksz:MIN(i*blocksz,npw), act_idx(j)) = & 
                w(1+(i-1)*blocksz:MIN(i*blocksz,npw), act_idx(j)) / &
                      precondition(1+(i-1)*blocksz:MIN(i*blocksz,npw))
     END DO ; END DO
     !$omp end parallel do
     !
     call start_clock('ppcg:dgemm')
     call threaded_assign( buffer, w, npwx, nact, act_idx )
     call threaded_memset( G, ZERO, nbnd*nact ) ! G(1:nbnd,1:nact) = ZERO
     CALL divide(inter_bgrp_comm,nbnd,n_start,n_end); my_n = n_end - n_start + 1; !write (*,*) nbnd,n_start,n_end
     if (overlap) then
        if (n_start .le. n_end) &
        CALL DGEMM( 'T','N', my_n, nact, npw2, 2.D0,spsi(1,n_start), npwx2, buffer, npwx2, 0.D0, G(n_start,1), nbnd )
        IF ( gstart == 2 ) CALL DGER( my_n, nact, -1.D0,spsi(1,n_start), npwx2, buffer, npwx2, G(n_start,1), nbnd )
     else
        if (n_start .le. n_end) &
        CALL DGEMM( 'T','N', my_n, nact, npw2, 2.D0, psi(1,n_start), npwx2, buffer, npwx2, 0.D0, G(n_start,1), nbnd )
        IF ( gstart == 2 ) CALL DGER( my_n, nact, -1.D0, psi(1,n_start), npwx2, buffer, npwx2, G(n_start,1), nbnd )
     end if
     CALL mp_sum( G(1:nbnd,1:nact), inter_bgrp_comm )
     !
     CALL mp_sum( G(1:nbnd,1:nact), intra_bgrp_comm )
     call stop_clock('ppcg:dgemm')
     !
     !     w = w - psi*G
     call start_clock('ppcg:dgemm')
     call threaded_assign( buffer, w, npwx, nact, act_idx, bgrp_root_only=.true. )
     if (n_start .le. n_end) &
     CALL DGEMM('N','N', npw2, nact, my_n, -ONE, psi(1,n_start), npwx2, G(n_start,1), nbnd, ONE, buffer, npwx2)
     CALL mp_sum( buffer(:,1:nact), inter_bgrp_comm )
     w(:,act_idx(1:nact)) = buffer(:,1:nact)
     call stop_clock('ppcg:dgemm')
     !
     ! ... Compute h*w
     call start_clock('ppcg:hpsi')
     IF ( gstart == 2 ) w(1,act_idx(1:nact)) = CMPLX( DBLE( w(1,act_idx(1:nact)) ), 0.D0, kind=DP)
     call threaded_assign( buffer1, w, npwx, nact, act_idx )
     CALL h_psi( npwx, npw, nact, buffer1, buffer )
     hw(:,act_idx(1:nact)) = buffer(:,1:nact)
     if (overlap) then ! ... Compute s*w
        CALL s_psi( npwx, npw, nact, buffer1, buffer )
        sw(:,act_idx(1:nact)) = buffer(:,1:nact)
     end if
     avg_iter = avg_iter + nact/dble(nbnd)
     call stop_clock('ppcg:hpsi')
     !
     ! ... orthogonalize p against psi and w
!ev     IF ( MOD(iter, rr_step) /= 1 ) THEN    ! In this case, P is skipped after each RR
     IF ( iter  /=  1 ) THEN
        !  G = spsi'p
        call start_clock('ppcg:dgemm')
        call threaded_memset( G, ZERO, nbnd*nact ) ! G(1:nact,1:nact) = ZERO
        if (overlap) then
           call threaded_assign( buffer, spsi, npwx, nact, act_idx )
        else
           call threaded_assign( buffer,  psi, npwx, nact, act_idx )
        end if
        call threaded_assign( buffer1,  p, npwx, nact, act_idx )
        CALL divide(inter_bgrp_comm,nact,n_start,n_end); my_n = n_end - n_start + 1; !write (*,*) nact,n_start,n_end
        if (n_start .le. n_end) &
        CALL DGEMM('T','N', my_n, nact, npw2, 2.D0, buffer(1,n_start), npwx2, buffer1, npwx2, 0.D0, G(n_start,1), nbnd)
        IF ( gstart == 2 ) CALL DGER( my_n, nact, -1.D0, buffer(1,n_start), npwx2, buffer1, npwx2, G(n_start,1), nbnd )
        CALL mp_sum( G(1:nact,1:nact), inter_bgrp_comm )
        !
        CALL mp_sum( G(1:nact,1:nact), intra_bgrp_comm )
        call stop_clock('ppcg:dgemm')
        !
        ! p = p - psi*G, hp = hp - hpsi*G, sp = sp - spsi*G
        call start_clock('ppcg:dgemm')
        call threaded_assign( buffer,  p, npwx, nact, act_idx, bgrp_root_only=.true. )
        call threaded_assign( buffer1,  psi, npwx, nact, act_idx )
        if (n_start .le. n_end) & ! could be done differently
        CALL DGEMM('N','N', npw2, nact, my_n,-ONE, buffer1(1,n_start), npwx2, G(n_start,1), nbnd, ONE, buffer, npwx2)
        CALL mp_sum( buffer(:,1:nact), inter_bgrp_comm )
        p(:,act_idx(1:nact)) = buffer(:,1:nact)
        call stop_clock('ppcg:dgemm')
        !
        call start_clock('ppcg:dgemm')
        call threaded_assign( buffer,  hp, npwx, nact, act_idx, bgrp_root_only=.true. )
        call threaded_assign( buffer1,  hpsi, npwx, nact, act_idx )
        if (n_start .le. n_end) &
        CALL DGEMM('N','N', npw2, nact, my_n,-ONE, buffer1(1,n_start), npwx2, G(n_start,1), nbnd, ONE, buffer, npwx2)
        CALL mp_sum( buffer(:,1:nact), inter_bgrp_comm )
        hp(:,act_idx(1:nact)) = buffer(:,1:nact)
        call stop_clock('ppcg:dgemm')
        !
        if (overlap) then
           call start_clock('ppcg:dgemm')
           call threaded_assign( buffer,  sp, npwx, nact, act_idx, bgrp_root_only=.true. )
           call threaded_assign( buffer1,  spsi, npwx, nact, act_idx )
           if (n_start .le. n_end) &
           CALL DGEMM('N','N', npw2, nact, my_n,-ONE, buffer1(1,n_start), npwx2, G(n_start,1), nbnd, ONE, buffer, npwx2)
           CALL mp_sum( buffer(:,1:nact), inter_bgrp_comm )
           sp(:,act_idx(1:nact)) = buffer(:,1:nact)
           call stop_clock('ppcg:dgemm')
        end if
     END IF
     !
     !
     !  ... for each sub-block construct the small projected matrices K and M
     !      and store in K_store and M_store
     !
     K_store = ZERO
     M_store = ZERO
     CALL divide(inter_bgrp_comm,nsb,n_start,n_end); my_n = n_end - n_start + 1; !write (*,*) nsb,n_start,n_end
     DO j = n_start, n_end
        !
        ! Get size of the sub-block and define indices of the corresponding columns
        IF ( j < nsb )  THEN
           l = sbsize
        ELSE
           l = sbsize_last
        END IF
        col_idx(1:l) = act_idx(  (/ (i, i = (j-1)*sbsize + 1, (j-1)*sbsize + l) /) )
        !
        ! ... form the local Gramm matrices (K,M)
        K = ZERO
        M = ZERO
        !
        call start_clock('ppcg:dgemm')
        call threaded_assign( buffer,  psi, npwx, l, col_idx )
        call threaded_assign( buffer1,  hpsi, npwx, l, col_idx )
        CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, K, sbsize3)
        IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, K, sbsize3 )
        !
        if (overlap) then
           call threaded_assign( buffer1,  spsi, npwx, l, col_idx )
        else
           call threaded_assign( buffer1,  buffer, npwx, l )
        end if
        CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, M, sbsize3)
        IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, M, sbsize3 )
        !
        ! ---
        call threaded_assign( buffer,  w, npwx, l, col_idx )
        call threaded_assign( buffer1,  hw, npwx, l, col_idx )
        CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, K(l+1, l+1), sbsize3)
        IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, K(l+1, l+1), sbsize3 )
        !
        if (overlap) then
           call threaded_assign( buffer1,  sw, npwx, l, col_idx )
        else
           call threaded_assign( buffer1,  buffer, npwx, l )
        end if
        CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, M(l+1, l+1 ), sbsize3)
        IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, M(l+1, l+1), sbsize3 )
        !
        ! ---
        call threaded_assign( buffer,  psi, npwx, l, col_idx )
        call threaded_assign( buffer1,  hw, npwx, l, col_idx )
        CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, K(1, l+1), sbsize3)
        IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, K(1, l+1), sbsize3 )
        !
        if (overlap) then
           call threaded_assign( buffer1,  sw, npwx, l, col_idx )
        else
           call threaded_assign( buffer1,  w, npwx, l, col_idx )
        end if
        CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, M(1, l+1), sbsize3)
        IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, M(1, l+1), sbsize3 )
        call stop_clock('ppcg:dgemm')
        !
        ! ---
        !
!ev        IF ( MOD(iter,rr_step) /= 1 ) THEN   ! In this case, P is skipped after each RR
        IF ( iter  /= 1 ) THEN
          call start_clock('ppcg:dgemm')
          call threaded_assign( buffer,  p, npwx, l, col_idx )
          call threaded_assign( buffer1,  hp, npwx, l, col_idx )
          CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, K(2*l + 1, 2*l+1), sbsize3)
          IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, K(2*l + 1, 2*l+1 ), sbsize3 )
          !
          if (overlap) then
             call threaded_assign( buffer1,  sp, npwx, l, col_idx )
          else
             call threaded_assign( buffer1,  buffer, npwx, l )
          end if
          CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, M(2*l + 1, 2*l+1), sbsize3)
          IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, M(2*l + 1, 2*l+1 ), sbsize3)
          !
          ! ---
          call threaded_assign( buffer,  psi, npwx, l, col_idx )
          call threaded_assign( buffer1,  hp, npwx, l, col_idx )
          CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, K(1, 2*l+1), sbsize3)
          IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, K(1, 2*l+1), sbsize3)
          !
          if (overlap) then
             call threaded_assign( buffer1,  sp, npwx, l, col_idx )
          else
             call threaded_assign( buffer1,  p, npwx, l, col_idx )
          end if
          CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, M(1, 2*l+1), sbsize3)
          IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, M(1, 2*l+1), sbsize3)
          call stop_clock('ppcg:dgemm')
          !
          ! ---
          !
          call start_clock('ppcg:dgemm')
          call threaded_assign( buffer,  w, npwx, l, col_idx )
          call threaded_assign( buffer1,  hp, npwx, l, col_idx )
          CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, K(l+1, 2*l+1), sbsize3)
          IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, K(l+1, 2*l+1), sbsize3)
          !
          if (overlap) then
             call threaded_assign( buffer1,  sp, npwx, l, col_idx )
          else
             call threaded_assign( buffer1,  p, npwx, l, col_idx )
          end if
          CALL DGEMM('T','N', l, l, npw2, 2.D0, buffer, npwx2, buffer1, npwx2, 0.D0, M(l+1, 2*l+1), sbsize3)
          IF ( gstart == 2 ) CALL DGER( l, l, -1.D0, buffer, npwx2, buffer1, npwx2, M(l+1, 2*l+1), sbsize3)
          call stop_clock('ppcg:dgemm')
          !
        END IF
        !
        ! ... store the projected matrices
        K_store( :, (j-1)*sbsize3 + 1 : j*sbsize3 ) = K
        M_store( :, (j-1)*sbsize3 + 1 : j*sbsize3 ) = M
        !
     END DO
     CALL mp_sum(K_store,inter_bgrp_comm)
     CALL mp_sum(M_store,inter_bgrp_comm)
     !
     CALL mp_sum(K_store,intra_bgrp_comm)
     CALL mp_sum(M_store,intra_bgrp_comm)
     !
     ! ... perform nsb 'separate RQ minimizations' and update approximate subspace

     idx(:) = 0 ! find the inactive columns to be kept by root_bgrp_id only
     if (my_bgrp_id == root_bgrp_id) then
        idx(1:nbnd) = 1 ; idx(act_idx(1:nact)) = 0
     end if
     DO j = n_start, n_end
       !
       ! Get size of the sub-block and define indices of the corresponding columns
       IF ( j < nsb )  THEN
          l = sbsize
       ELSE
          l = sbsize_last
       END IF

       col_idx(1:l) = act_idx( (/ (i, i = (j-1)*sbsize + 1, (j-1)*sbsize + l) /)  )
       !
       K = K_store(:, (j-1)*sbsize3 + 1 : j*sbsize3)
       M = M_store(:, (j-1)*sbsize3 + 1 : j*sbsize3)
       !
       lwork  =  1 + 18*sbsize + 18*sbsize**2
       liwork =  3 + 15*sbsize
!ev       IF ( MOD(iter, rr_step) /= 1) THEN    ! set the dimension of the separate projected eigenproblem
       IF ( iter /= 1 ) THEN    ! set the dimension of the separate projected eigenproblem
          dimp = 3*l
       ELSE
          dimp = 2*l
       END IF
       !
       CALL DSYGVD(1, 'V','U', dimp, K, sbsize3, M, sbsize3, D, work, lwork, iwork, liwork, info)
       IF (info /= 0) THEN
          ! reset the matrix and try again with psi and w only
          K = K_store(:, (j-1)*sbsize3 + 1 : j*sbsize3)
          M = M_store(:, (j-1)*sbsize3 + 1 : j*sbsize3)
          dimp = 2*l
          CALL DSYGVD(1, 'V','U', dimp, K, sbsize3, M, sbsize3, D, work, lwork, iwork, liwork, info)
          IF (info /= 0) THEN
             CALL errore( 'ppcg ',' dsygvd failed ', info )
             STOP
          END IF
       END IF
       !
       coord_psi(1 : l, 1 : l) = K(1 : l, 1 : l)
       coord_w(1 : l, 1 : l) = K(l+1 : 2*l, 1 : l)
       !
       ! ... update the sub-block of P and AP
!ev       IF ( MOD(iter, rr_step) /= 1 ) THEN
!sdg      IF ( iter /= 1 ) THEN
       IF ( dimp == 3*l ) THEN
          !
          coord_p(1 : l, 1 : l) = K(2*l+1 : 3*l, 1 : l)
          !
          call start_clock('ppcg:dgemm')
          call threaded_assign( buffer1,  p, npwx, l, col_idx )
          CALL DGEMM('N','N',npw2, l, l, ONE, buffer1, npwx2, coord_p, sbsize, ZERO, buffer, npwx2)
          call threaded_assign( buffer1,  w, npwx, l, col_idx )
          CALL DGEMM('N','N', npw2, l, l, ONE, buffer1, npwx2, coord_w, sbsize, ONE, buffer, npwx2)
          p(:,col_idx(1:l))  = buffer(:,1:l)
          call stop_clock('ppcg:dgemm')
          !
          call start_clock('ppcg:dgemm')
          call threaded_assign( buffer1,  hp, npwx, l, col_idx )
          CALL DGEMM('N','N',npw2, l, l, ONE, buffer1, npwx2, coord_p, sbsize, ZERO, buffer, npwx2)
          call threaded_assign( buffer1,  hw, npwx, l, col_idx )
          CALL DGEMM('N','N', npw2, l, l, ONE, buffer1, npwx2, coord_w, sbsize, ONE, buffer, npwx2)
          hp(:,col_idx(1:l))  = buffer(:,1:l)
          call stop_clock('ppcg:dgemm')
          !
          if (overlap) then
             call start_clock('ppcg:dgemm')
             call threaded_assign( buffer1,  sp, npwx, l, col_idx )
             CALL DGEMM('N','N',npw2, l, l, ONE, buffer1, npwx2, coord_p, sbsize, ZERO, buffer, npwx2)
             call threaded_assign( buffer1,  sw, npwx, l, col_idx )
             CALL DGEMM('N','N', npw2, l, l, ONE, buffer1, npwx2, coord_w, sbsize, ONE, buffer, npwx2)
             sp(:,col_idx(1:l))  = buffer(:,1:l)
             call stop_clock('ppcg:dgemm')
          end if
       ELSE
          !
          call start_clock('ppcg:dgemm')
          call threaded_assign( buffer1,  w, npwx, l, col_idx )
          CALL DGEMM('N','N',npw2, l, l, ONE, buffer1, npwx2, coord_w, sbsize, ZERO, buffer, npwx2)
          p(:,col_idx(1:l)) = buffer(:, 1:l)
          call stop_clock('ppcg:dgemm')
          !
          call start_clock('ppcg:dgemm')
          call threaded_assign( buffer1,  hw, npwx, l, col_idx )
          CALL DGEMM('N','N',npw2, l, l, ONE, buffer1, npwx2, coord_w, sbsize, ZERO, buffer, npwx2)
          hp(:,col_idx(1:l)) = buffer(:, 1:l)
          call stop_clock('ppcg:dgemm')
          !
          if (overlap) then
             call start_clock('ppcg:dgemm')
             call threaded_assign( buffer1,  sw, npwx, l, col_idx )
             CALL DGEMM('N','N',npw2, l, l, ONE, buffer1, npwx2, coord_w, sbsize, ZERO, buffer, npwx2)
             sp(:,col_idx(1:l)) = buffer(:, 1:l)
             call stop_clock('ppcg:dgemm')
          end if
       END IF
       !
       ! Update the sub-blocks of psi and hpsi (and spsi)
       call start_clock('ppcg:dgemm')
       call threaded_assign( buffer1,  psi, npwx, l, col_idx )
       CALL DGEMM('N','N',npw2, l, l, ONE, buffer1, npwx2, coord_psi, sbsize, ZERO, buffer, npwx2)
       psi(:,col_idx(1:l))  = buffer(:,1:l)  + p(:,col_idx(1:l))
       call stop_clock('ppcg:dgemm')
       !
       call start_clock('ppcg:dgemm')
       call threaded_assign( buffer1,  hpsi, npwx, l, col_idx )
       CALL DGEMM('N','N',npw2, l, l, ONE, buffer1, npwx2, coord_psi, sbsize, ZERO, buffer, npwx2)
       hpsi(:,col_idx(1:l)) = buffer(:,1:l) + hp(:,col_idx(1:l))
       call stop_clock('ppcg:dgemm')
       !
       if (overlap) then
          call start_clock('ppcg:dgemm')
          call threaded_assign( buffer1,  spsi, npwx, l, col_idx )
          CALL DGEMM('N','N',npw2, l, l, ONE, buffer1, npwx2, coord_psi, sbsize, ZERO, buffer, npwx2)
          spsi(:,col_idx(1:l)) = buffer(:,1:l) + sp(:,col_idx(1:l))
          call stop_clock('ppcg:dgemm')
       end if
       !
       idx(col_idx(1:l)) = 1 ! keep track of which columns this bgrp has acted on
     END DO  ! end 'separate RQ minimizations'
     ! set to zero the columns not assigned to this bgrp, inactive colums are assigned to root_bgrp
     !omp parallel do
     do j=1,nbnd
        if (idx(j)==0) then
           psi (:,j) = C_ZERO ; hpsi (:,j) = C_ZERO ; p(:,j) = C_ZERO ; hp(:,j) = C_ZERO
           if (overlap) then
              spsi (:,j) = C_ZERO ; sp(:,j) = C_ZERO
           end if
        end if
     end do
     !omp end parallel do
     CALL mp_sum(psi ,inter_bgrp_comm)
     CALL mp_sum(hpsi,inter_bgrp_comm)
     CALL mp_sum(p ,inter_bgrp_comm)
     CALL mp_sum(hp,inter_bgrp_comm)
     if (overlap) then
        CALL mp_sum(spsi,inter_bgrp_comm)
        CALL mp_sum(sp,inter_bgrp_comm)
     end if
    !
    !
    ! ... Perform the RR procedure every rr_step
!    IF ( (MOD(iter, rr_step) == 0) .AND. (iter /= maxter) ) THEN
    IF ( MOD(iter, rr_step) == 0 ) THEN
       !
       call start_clock('ppcg:RR')
       CALL extract_epairs_dmat(npw, nbnd, npwx, e, psi, hpsi, spsi )
       call stop_clock('ppcg:RR')
       !
       IF (print_info >= 2) WRITE(stdout, *) 'RR has been invoked.' ; !CALL flush( stdout )
       !
       ! ... Compute the new residual vector block by evaluating
       !     residuals for individual eigenpairs in psi and e
       if (overlap) then
          !$omp parallel do collapse(2)
          DO j = 1, nbnd ; DO i=1,nblock
             w( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j ) = hpsi( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j ) &
                                                 - spsi( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j )*e( j )
          END DO ; END DO
          !$omp end parallel do
       else
          !$omp parallel do collapse(2)
          DO j = 1, nbnd ; DO i=1,nblock
             w( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j ) = hpsi( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j ) &
                                                 -  psi( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j )*e( j )
          END DO ; END DO
          !$omp end parallel do
       end if
       !
       ! ... Lock converged eigenpairs (set up act_idx and nact)
       call start_clock('ppcg:lock')
       nact_old = nact;
       CALL lock_epairs(npw, nbnd, btype, w, npwx, lock_tol, nact, act_idx)
       call stop_clock('ppcg:lock')
       !
       ! ... Set up iteration parameters after locking
       CALL setup_param
       !
       !
       trG1  =  0.D0
       trdif = -1.D0
       trG   = SUM( e(act_idx(1:nact)) )
       !
    ELSE
       !
!! EV begin
      ! ... orthogonalize psi and update hpsi accordingly
      IF ( .NOT. force_repmat ) THEN
         !
         call threaded_assign( buffer,  psi, npwx, nact, act_idx )
         if (overlap) then
            call threaded_assign( buffer1,  spsi, npwx, nact, act_idx )
         else
            call threaded_assign( buffer1,  buffer, npwx, nact )
         end if
         !
         call start_clock('ppcg:cholQR')
         CALL cholQR_dmat(npw, nact, buffer, buffer1, npwx, Gl, desc)
         call stop_clock('ppcg:cholQR')
         !
         psi(:,act_idx(1:nact)) = buffer(:,1:nact)
         !
         call threaded_assign( buffer1,  hpsi, npwx, nact, act_idx )
         call start_clock('ppcg:DTRSM')
         CALL dgemm_dmat( npw, nact, npwx, desc, ONE, buffer1, Gl, ZERO, buffer )
         call stop_clock('ppcg:DTRSM')
         !
         hpsi(:,act_idx(1:nact)) = buffer(:,1:nact)
         !
         if (overlap) then
            call threaded_assign( buffer1,  spsi, npwx, nact, act_idx )
            call start_clock('ppcg:DTRSM')
            CALL dgemm_dmat( npw, nact, npwx, desc, ONE, buffer1, Gl, ZERO, buffer )
            call stop_clock('ppcg:DTRSM')
            !
            spsi(:,act_idx(1:nact)) = buffer(:,1:nact)
         end if
      ELSE
         !
         call threaded_assign( buffer,  psi, npwx, nact, act_idx )
         if (overlap) then
            call threaded_assign( buffer1,  spsi, npwx, nact, act_idx )
         else
            call threaded_assign( buffer1,  buffer, npwx, nact )
         end if
         !
         call start_clock('ppcg:cholQR')
         CALL cholQR(npw, nact, buffer, buffer1, npwx, G, nbnd)
         call stop_clock('ppcg:cholQR')
         !
         psi(:,act_idx(1:nact)) = buffer(:,1:nact)
         !
         call threaded_assign( buffer,  hpsi, npwx, nact, act_idx )
         !
         call start_clock('ppcg:DTRSM')
         CALL DTRSM('R', 'U', 'N', 'N', npw2, nact, ONE, G, nbnd, buffer, npwx2)
         call stop_clock('ppcg:DTRSM')
         !
         hpsi(:,act_idx(1:nact)) = buffer(:,1:nact)
         !
         if (overlap) then
            call threaded_assign( buffer,  spsi, npwx, nact, act_idx )
            !
            call start_clock('ppcg:DTRSM')
            CALL DTRSM('R', 'U', 'N', 'N', npw2, nact, ONE, G, nbnd, buffer, npwx2)
            call stop_clock('ppcg:DTRSM')
            !
            spsi(:,act_idx(1:nact)) = buffer(:,1:nact)
         end if
      END IF
!! EV end
       !
       ! ... Compute the new subspace residual for active columns
       !
       !  G = psi'hpsi
       call threaded_assign( buffer,  psi, npwx, nact, act_idx )
       call threaded_assign( buffer1,  hpsi, npwx, nact, act_idx )
       call start_clock('ppcg:dgemm')
       call threaded_memset( G, ZERO, nbnd*nbnd ) ! G = ZERO
       CALL divide(inter_bgrp_comm,nact,n_start,n_end); my_n = n_end - n_start + 1; !write (*,*) nact,n_start,n_end
       if (n_start .le. n_end) &
       CALL DGEMM('T','N', nact, my_n, npw2, 2.D0, buffer, npwx2, buffer1(1,n_start), npwx2, 0.D0, G(1,n_start), nbnd)
       IF ( gstart == 2 ) CALL DGER( nact, my_n, -1.D0, buffer, npwx2, buffer1(1,n_start), npwx2, G(1,n_start), nbnd )
       CALL mp_sum(G(1:nact,1:nact), inter_bgrp_comm)
       !
       CALL mp_sum(G(1:nact,1:nact), intra_bgrp_comm)
       call stop_clock('ppcg:dgemm')
       !
       ! w = hpsi - spsi*G
       call threaded_assign( buffer,  hpsi, npwx, nact, act_idx, bgrp_root_only=.true. )
       if (overlap) then
          call threaded_assign( buffer1,  spsi, npwx, nact, act_idx )
       else
          call threaded_assign( buffer1,  psi, npwx, nact, act_idx )
       end if
       call start_clock('ppcg:dgemm')
       if (n_start .le. n_end) &
       CALL DGEMM('N','N',npw2, nact, my_n, -ONE, buffer1(1,n_start), npwx2, G(n_start,1), nbnd, ONE, buffer, npwx2)
       CALL mp_sum( buffer(:,1:nact), inter_bgrp_comm )
       w(:,act_idx(1:nact)) = buffer(:,1:nact);

       call stop_clock('ppcg:dgemm')
       !
       ! ... Compute trace of the projected matrix on current iteration
       ! trG1  = get_trace( G(1:nact, 1:nact), nact )
       trG1  = get_trace( G, nbnd, nact )
       trdif = ABS(trG1 - trG)
       trG   = trG1
       !
    END IF
    !
    ! Print iteration info ...
    IF (print_info >= 1) THEN
       WRITE(stdout, '("iter: ", I5, " nact = ", I5, ", trdif = ", 1pD9.2, ", trtol = ", 1pD9.2 )') iter, nact, trdif, trtol
       IF (print_info == 3) THEN
          CALL print_rnrm
          WRITE(stdout,'("Res. norm:  ", 1pD9.2)') res_array(iter)
       END IF
       CALL flush( stdout )
    END IF
    !
    total_iter = iter
    iter   = iter + 1
    !
    !
 END DO   !---End the main loop
 !
! IF (nact > 0) THEN
 IF ( MOD(iter-1, rr_step) /= 0 ) THEN        ! if RR has not just been performed
 ! if nact==0 then the RR has just been performed
 ! in the main loop
    call start_clock('ppcg:RR')
    CALL extract_epairs_dmat(npw, nbnd, npwx, e, psi, hpsi, spsi )
    call stop_clock('ppcg:RR')
    !
    ! ... Compute residuals
    if (overlap) then
       !$omp parallel do collapse(2)
       DO j = 1, nbnd ; DO i=1,nblock
          w( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j ) = hpsi( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j ) &
                                              - spsi( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j )*e( j )
       END DO ; END DO
       !$omp end parallel do
    else
       !$omp parallel do collapse(2)
       DO j = 1, nbnd ; DO i=1,nblock
          w( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j ) = hpsi( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j ) &
                                              -  psi( 1+(i-1)*blocksz:MIN(i*blocksz,npw), j )*e( j )
       END DO ; END DO
       !$omp end parallel do
    end if
    !
    ! ... Get the number of converged eigenpairs and their indices
    !     Note: The tolerance is 10*lock_tol, i.e., weaker tham lock_tol
! E.V. notconv issue should be addressed
    call start_clock('ppcg:lock')
    CALL lock_epairs(npw, nbnd, btype, w, npwx, 10*lock_tol, nact, act_idx)
    call stop_clock('ppcg:lock')
    !
 END IF
 !
! E.V. notconv issue comment
 notconv = 0 ! nact
 !
 IF (print_info >= 1) THEN
    WRITE(stdout, *) '-----------PPCG result summary ...  ----------------'
    WRITE(stdout, '("avg_iter: ", f6.2,  ", notconv: ", I5)') avg_iter, notconv
    CALL flush( stdout )
 END IF
 !
 CALL deallocate_all
 !
 CALL stop_clock( 'ppcg_gamma' )
 !
!!!EV-BANDS

if (print_info == 3) then
    write (stdout,'(1pD9.2)') ( res_array(j), j=1,maxter )
end if

 !
 RETURN
   !
CONTAINS
  !
  SUBROUTINE allocate_all
    !
    ! This subroutine allocates memory for the eigensolver
    !
    INTEGER :: nx
    ! maximum local block dimension
    !
    ALLOCATE ( hpsi(npwx,nbnd), stat = ierr )
    IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate hpsi ', ABS(ierr) )
    if (overlap) ALLOCATE ( spsi(npwx,nbnd), stat = ierr )
    IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate spsi ', ABS(ierr) )
    ALLOCATE ( w(npwx,nbnd), hw(npwx,nbnd), stat = ierr )
    IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate w and hw ', ABS(ierr) )
    if (overlap) ALLOCATE ( sw(npwx,nbnd), stat = ierr )
    IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate sw ', ABS(ierr) )
    ALLOCATE ( p(npwx,nbnd), hp(npwx,nbnd), stat = ierr )
    IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate p and hp ', ABS(ierr) )
    if (overlap) ALLOCATE ( sp(npwx,nbnd), stat = ierr )
    IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate sp ', ABS(ierr) )
    ALLOCATE ( K(sbsize3, sbsize3), M(sbsize3,sbsize3), stat = ierr )
    IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate K and M ', ABS(ierr) )
    ALLOCATE ( work( 1 + 18*sbsize + 18*sbsize**2 ), iwork(3 + 15*sbsize), stat = ierr )
    IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate lapack work arrays ', ABS(ierr) )
    !
    ALLOCATE( irc_ip( np_ortho(1) ), STAT=ierr )
    IF( ierr /= 0 ) CALL errore( 'ppcg ',' cannot allocate irc_ip ', ABS(ierr) )
    ALLOCATE( nrc_ip( np_ortho(1) ), STAT=ierr )
    IF( ierr /= 0 ) CALL errore( 'ppcg ',' cannot allocate nrc_ip ', ABS(ierr) )
    ALLOCATE( rank_ip( np_ortho(1), np_ortho(2) ), STAT=ierr )
    IF( ierr /= 0 ) CALL errore( 'ppcg ',' cannot allocate rank_ip ', ABS(ierr) )
    !
    CALL desc_init( nbnd, desc, irc_ip, nrc_ip  )
    !
    nx = desc%nrcx
    !
    IF ( la_proc ) THEN
       ALLOCATE( Gl( nx, nx ), STAT=ierr )
    ELSE
       ALLOCATE( Gl( 1, 1 ), STAT=ierr )
    END IF
    IF( ierr /= 0 ) CALL errore( 'ppcg ',' cannot allocate Gl ', ABS(ierr) )

  END SUBROUTINE allocate_all
  !
  !
  !
  SUBROUTINE cholQR(n, k, X, SX, ldx,  R, ldr)
    !
    !  This subroutine orthogonalizes X using the Choleski decomposition.
    !  The matrix X'X and its Choleski decomposition is replicated on all processors.
    !  TBD: If the Choleslki orthogonalization fails, a slower but more accuarte
    !  Householder QR is performed.
    !
    IMPLICIT NONE
    !
    ! ... I/O variables
    !
    INTEGER,     INTENT (IN) :: n, k, ldx, ldr
    COMPLEX(DP), INTENT (INOUT) :: X(ldx,*), SX(ldx,*)
    REAL(DP),    INTENT(OUT) :: R(ldr,*)
    !
    ! ... local variables
    !
    REAL(DP)   :: XTX(k,k)
    INTEGER    :: n2, ldx2
    INTEGER    :: ierr = 0, info = 0
    ldx2 = ldx*2
    n2 = n*2
    !
    ! ... do Cholesky QR unless X is rank deficient
    !
    CALL DGEMM('T','N', k, k, n2, 2.D0, X, ldx2, SX, ldx2, 0.D0, XTX, k)
    IF ( gstart == 2 ) CALL DGER( k, k, -1.D0, X, ldx2, SX, ldx2, XTX, k )
    !
    CALL mp_sum( XTX, intra_bgrp_comm )
    !
    CALL DPOTRF('U', k, XTX, k, info)
    IF ( info == 0 ) THEN
       !
       ! ... triangualar solve
       CALL DTRSM('R', 'U', 'N', 'N', n2, k, ONE, XTX, k, X, ldx2)
       !
    ELSE
       ! TBD: QR
       WRITE(stdout,*) '[Q, R] = qr(X, 0) failed'
       STOP
!           ![X, R] = qr(X, 0)
!           ! QR without forming Q
!           !
!           call zgeqrf(nn,kk,X,nn,tau,wqr,lwqr,info)
!           !
!           if (info<0) then
!              write(*,*), '[Q, R] = qr(X, 0) failed'
!              stop
!           endif
!           ! QR: constructing Q
!           !
!           call zungqr(nn,kk,kk,X,nn,tau,wqr,lwqr,info)
!           !
    END IF
    !
    ! ... also return R factor if needed
    !
    CALL DLACPY('U', k, k,  XTX, k,  R, ldr)
    !
    RETURN
    !
  END SUBROUTINE cholQR
  !
  !
  !
  SUBROUTINE cholQR_dmat(npw, k, X, SX, npwx,  Rl, desc)
    !
    ! Distributed version of cholQR
    !
    IMPLICIT NONE
    !
    ! ... I/O variables
    !
    INTEGER,     INTENT (IN) :: npw, k, npwx
    COMPLEX(DP), INTENT (INOUT) :: X(npwx,k), SX(npwx,k)
    TYPE(la_descriptor), INTENT (IN)  :: desc
    REAL(DP),    INTENT(OUT) :: Rl(:, :)
    ! inverse of the upper triangular Cholesky factor
    !
    ! ... local variables
    !
    COMPLEX(DP)  :: buffer(npwx,k)
    REAL(DP), ALLOCATABLE   :: XTXl(:,:)
    INTEGER    :: nx, ierr = 0
#ifdef __SCALAPACK
    INTEGER     :: desc_sca( 16 ), info
#endif
    !
    nx = desc%nrcx
    !
    IF ( la_proc ) THEN
       !
       ALLOCATE( XTXl( nx, nx ), STAT=ierr )
       IF( ierr /= 0 ) &
          CALL errore( 'ppcg ',' cannot allocate XTXl ', ABS(ierr) )
       !
    ELSE
       !
       ALLOCATE( XTXl( 1, 1 ), STAT=ierr )
       IF( ierr /= 0 ) &
          CALL errore( 'ppcg ',' cannot allocate XTXl ', ABS(ierr) )
       !
    END IF
    !
    ! ... Perform Cholesky of X'X
    !
    CALL compute_distmat(XTXl, desc, X, SX, k)
    !
    IF ( la_proc ) THEN
       !
#ifdef __SCALAPACK
       CALL descinit( desc_sca, k, k, nx, nx, 0, 0, ortho_cntx, SIZE( XTXl, 1 ), info )
       IF( info /= 0 ) CALL errore( ' ppcg ', ' descinit ', ABS( info ) )
       !
       CALL PDPOTRF( 'U', k, XTXl, 1, 1, desc_sca, info )
!      IF( info /= 0 ) CALL errore( ' ppcg ', ' problems computing cholesky ', ABS( info ) )
       !
       IF ( info == 0 ) THEN
          !
!          ! set the lower triangular part to zero
!          CALL sqr_dsetmat( 'L', k, ZERO, XTXl, size(XTXl,1), desc )
          !
          ! find inverse of the upper triangular Cholesky factor R
          CALL PDTRTRI( 'U', 'N', k, XTXl, 1, 1, desc_sca, info )
          IF( info /= 0 ) CALL errore( ' ppcg ', ' problems computing inverse ', ABS( info ) )
          !
          ! set the lower triangular part to zero
          CALL sqr_dsetmat( 'L', k, ZERO, XTXl, size(XTXl,1), desc )
       !
       ELSE
       ! TBD: QR
          WRITE(stdout,*) '[Q, R] = qr(X, 0) failed'
          STOP
!           ![X, R] = qr(X, 0)
!           ! QR without forming Q
!           !
!           call zgeqrf(nn,kk,X,nn,tau,wqr,lwqr,info)
!           !
!           if (info<0) then
!              write(*,*), '[Q, R] = qr(X, 0) failed'
!              stop
!           endif
!           ! QR: constructing Q
!           !
!           call zungqr(nn,kk,kk,X,nn,tau,wqr,lwqr,info)
!           !
       END IF
#else
       CALL qe_pdpotrf( XTXl, nx, k, desc )
       !
       CALL qe_pdtrtri ( XTXl, nx, k, desc )
#endif
    !
    !
    END IF
    !
    CALL dgemm_dmat( npw, k, npwx, desc, ONE, X, XTXl, ZERO, buffer )
    !
    X = buffer
    ! ... also return R factor
    Rl = XTXl
    !
    DEALLOCATE(XTXl)
    !
    RETURN
    !
  END SUBROUTINE cholQR_dmat
  !
  !
  !
  SUBROUTINE lock_epairs(npw, nbnd, btype, w, npwx, tol, nact, act_idx)
     !
     ! Lock converged eigenpairs: detect "active" columns of w
     ! by checking if each column has norm greater than tol.
     ! Returns the number of active columns and their indices.
     !
     IMPLICIT NONE
     !
     ! ... I/O variables
     !
     INTEGER,     INTENT (IN) :: npw, npwx, nbnd, btype(nbnd)
     COMPLEX(DP), INTENT (IN) :: w(npwx,nbnd)
     REAL(DP),    INTENT (IN) :: tol
     INTEGER,     INTENT(OUT)   :: nact, act_idx(nbnd)
     !
     ! ... local variables
     !
     INTEGER         :: j
     REAL(DP)        :: rnrm_store(nbnd), band_tollerance
     !
     nact = 0
     ! ... Compute norms of each column of psi
     rnrm_store = 0.D0
     CALL divide(inter_bgrp_comm,nbnd,n_start,n_end); my_n = n_end - n_start + 1; !write (*,*) nbnd,n_start,n_end
     DO j = n_start, n_end
        !
        rnrm_store(j)   =  2.D0*DDOT(npw2, w(:,j), 1, w(:,j), 1)
        IF ( gstart == 2 )  rnrm_store(j) = rnrm_store(j) - DBLE( w(1,j) )**2
        !
     END DO
     CALL mp_sum( rnrm_store, inter_bgrp_comm )
     !
     CALL mp_sum( rnrm_store, intra_bgrp_comm )
     !
     DO j = 1, nbnd
        !
        if ( btype(j) == 0 ) then
             band_tollerance = max(2.5*tol,1.d-3)
        else
             band_tollerance = tol
        end if
        !
        rnrm_store(j) = SQRT( rnrm_store(j) )
        !
        IF ( (print_info >= 2) .AND. (iter > 1) )  THEN
          write(stdout, '( "Eigenvalue ", I5, " = ", 1pe12.4, ". Residual norm = ",  1pe9.2)') &
                      j, e(j), rnrm_store(j)
        END IF
        !
        IF ( rnrm_store(j) > band_tollerance ) THEN
           nact = nact + 1
           act_idx(nact) = j
        END IF
        !
     END DO
     !
     !
  END SUBROUTINE lock_epairs
  !
  !
  SUBROUTINE setup_param
     !
     ! Based on the information about active columns of psi,
     ! set up iteration parameters, such as:
     !   - number of subblock
     !   - size of the last sub-block
     !   - tolerance level for the trace difference of reduced hamiltonians
     !     on consecutive iterations
     !   - replicate or re-distribute the Gram matrix G
     !
     IMPLICIT NONE
     !
     ! ... I/O variables
     !
!     INTEGER,     INTENT (IN) :: nbnd, nact, act_idx(nbnd), sbsize
!     INTEGER,     INTENT(OUT) :: nsb, sbsize_last
!     REAL(DP),    INTENT(OUT) :: tol
     !
     ! ... local variables
     !
     INTEGER         :: ierr
     INTEGER :: nx, act_thresh
     ! maximum local block dimension
     ! Threshold on the number of active vectors that determines if
     ! Choleski is distributed or replicated
     !
     !
     ! ... Compute the number of sub-blocks and the size of the last sub-block
     sbsize_last = sbsize
     nsb   =  FLOOR( DBLE(nact)/DBLE(sbsize) )
     IF ( MOD( nact, sbsize ) /= 0) THEN
        sbsize_last =  nact - sbsize*nsb
        nsb         =  nsb + 1
     END IF
     !
     ! ... Compute the current tolerance level for nact pairs
     trtol   = ethr*SQRT(DBLE(nact)) ! MIN( ethr*SQRT(DBLE(nact)), 1.0D-2 )
     !
     ! ... Redistribute matrices for Cholesky because number of active vectors has changed
     !
     ! Don't want to run distributed Cholesky for matrices of size <= 100
     act_thresh = MAX( 100, np_ortho(1) )
     !
     IF ( ( nact > act_thresh ) .AND. (nact /= nact_old) ) THEN
        !
        IF ( ALLOCATED(Gl) ) DEALLOCATE(Gl)
        !
        CALL desc_init( nact, desc, irc_ip, nrc_ip  )
        !
        nx = desc%nrcx
        !
        IF ( la_proc ) THEN
           !
           ALLOCATE( Gl( nx, nx ), STAT=ierr )
           IF( ierr /= 0 ) &
              CALL errore( 'ppcg ',' cannot allocate Gl ', ABS(ierr) )
           !
        ELSE
           !
           ALLOCATE( Gl( 1, 1 ), STAT=ierr )
           IF( ierr /= 0 ) &
           CALL errore( 'ppcg ',' cannot allocate Gl ', ABS(ierr) )
           !
        END IF
        !
        force_repmat = .FALSE.
        !
     ELSE
       ! replicate Cholesky because number of active vectors is small
       !
       IF (nact <= act_thresh) THEN
          !
          force_repmat = .TRUE.
          !
          IF ( ALLOCATED(Gl) ) DEALLOCATE(Gl)
          !
        ELSE
          !
          force_repmat = .FALSE.
          !
        END IF
           !
     END IF
     !
     !
     ! ... Allocate storage for the small matrices in separate minimization loop
     IF ( ALLOCATED(K_store) ) DEALLOCATE(K_store)
     IF ( ALLOCATED(M_store) ) DEALLOCATE(M_store)
     ALLOCATE ( K_store(sbsize3, sbsize3*nsb), M_store(sbsize3,sbsize3*nsb), stat = ierr )
     IF (ierr /= 0) &
        CALL errore( 'ppcg ',' cannot allocate K_store and M_store ', ABS(ierr) )
     !
     RETURN
     !
  END SUBROUTINE setup_param
  !
  !
  !
  !
  SUBROUTINE extract_epairs_dmat(npw, nbnd, npwx, e, psi, hpsi, spsi)
     !
     ! Perform the Rayleigh-Ritz to "rotate" psi to eigenvectors
     ! The Gram matrices are distributed over la processor group
     !
     !
     IMPLICIT NONE
     !
     ! ... I/O variables
     !
     INTEGER,     INTENT (IN)  :: npw, npwx, nbnd
     REAL(DP),    INTENT (OUT) :: e(nbnd)
     COMPLEX(DP), INTENT (INOUT)  :: psi(npwx,nbnd), hpsi(npwx,nbnd), spsi(npwx,nbnd)
!     LOGICAL,     INTENT(IN), OPTIONAL :: ortho
     ! ortho = .true.(default) then orthogonalization of psi prior to the RR is enforced
     !
     ! ... local variables
     !
     REAL (DP), ALLOCATABLE    :: Hl(:,:), Sl(:,:)
     ! local part of projected Hamiltonian and of the overlap matrix
     TYPE(la_descriptor)       :: desc
     !
     ! Matrix distribution descriptors to temporary store the "global" current descriptor
     LOGICAL :: la_proc_store
     ! flag to distinguish procs involved in linear algebra
     INTEGER, ALLOCATABLE :: irc_ip_store( : )
     INTEGER, ALLOCATABLE :: nrc_ip_store( : )
     INTEGER, ALLOCATABLE :: rank_ip_store( :, : )
     !
     COMPLEX(DP), ALLOCATABLE  :: psi_t(:, :), hpsi_t(:, :), spsi_t(:, :)
     REAL(DP), ALLOCATABLE     :: vl(:,:)
     COMPLEX(DP)               :: buffer(npwx,nbnd)
!     REAL(DP)                  :: R(nbnd, nbnd)
     INTEGER                   :: nx
!     LOGICAL                   :: do_orth
     !
     ALLOCATE ( psi_t(npwx,nbnd), hpsi_t(npwx,nbnd), stat = ierr )
     IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate psi_t and hpsi_t ', ABS(ierr) )
     if (overlap) ALLOCATE ( spsi_t(npwx,nbnd), stat = ierr )
     IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate spsi_t ', ABS(ierr) )
     !
     ! Store current distributed matrix descriptor information
     ALLOCATE ( irc_ip_store( np_ortho(1)  ), stat = ierr )
     IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate irc_ip_store ', ABS(ierr) )
     !
     ALLOCATE ( nrc_ip_store( np_ortho(1) ), stat = ierr )
     IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate nrc_ip_store ', ABS(ierr) )
     !
     ALLOCATE ( rank_ip_store( np_ortho(1), np_ortho(2) ), stat = ierr )
     IF (ierr /= 0) CALL errore( 'ppcg ',' cannot allocate rank_ip_store ', ABS(ierr) )
     !
     irc_ip_store  = irc_ip
     nrc_ip_store  = nrc_ip
     rank_ip_store = rank_ip
     !
     CALL desc_init( nbnd, desc, irc_ip, nrc_ip  )
     !
     nx = desc%nrcx
     !
     IF ( la_proc ) THEN
        !
        ALLOCATE( vl( nx, nx ), STAT=ierr )
        IF( ierr /= 0 ) &
           CALL errore( 'ppcg ',' cannot allocate vl ', ABS(ierr) )
        !
        ALLOCATE( Sl( nx, nx ), STAT=ierr )
        IF( ierr /= 0 ) &
          CALL errore( 'ppcg ',' cannot allocate Sl ', ABS(ierr) )
        !
        ALLOCATE( Hl( nx, nx ), STAT=ierr )
        IF( ierr /= 0 ) &
          CALL errore( 'ppcg ',' cannot allocate Hl ', ABS(ierr) )
        !
     ELSE
        !
        ALLOCATE( vl( 1, 1 ), STAT=ierr )
        IF( ierr /= 0 ) &
           CALL errore( 'pregterg ',' cannot allocate vl ', ABS(ierr) )
        !
        ALLOCATE( Sl( 1, 1 ), STAT=ierr )
        IF( ierr /= 0 ) &
           CALL errore( 'ppcg ',' cannot allocate Sl ', ABS(ierr) )
        !
        ALLOCATE( Hl( 1, 1 ), STAT=ierr )
        IF( ierr /= 0 ) &
           CALL errore( 'ppcg ',' cannot allocate Hl ', ABS(ierr) )
        !
     END IF
     !
     !
     !  G = psi'*hpsi
     CALL compute_distmat(Hl, desc, psi, hpsi, nbnd)
     if (overlap) then
        CALL compute_distmat(Sl, desc, psi, spsi, nbnd)
     else
        CALL compute_distmat(Sl, desc, psi,  psi, nbnd)
     end if
     !
     ! ... diagonalize the reduced hamiltonian
     !     Calling block parallel algorithm
     !
     IF ( do_distr_diag_inside_bgrp ) THEN ! NB on output of prdiaghg e and vl are the same across ortho_parent_comm
        ! only the first bgrp performs the diagonalization
        IF( my_bgrp_id == root_bgrp_id) CALL prdiaghg( nbnd, Hl, Sl, nx, e, vl, desc )
        IF( nbgrp > 1 ) THEN ! results must be brodcast to the other band groups
          CALL mp_bcast( vl, root_bgrp_id, inter_bgrp_comm )
          CALL mp_bcast( e,  root_bgrp_id, inter_bgrp_comm )
        ENDIF
     ELSE
        CALL prdiaghg( nbnd, Hl, Sl, nx, e, vl, desc )
     END IF
     !
     ! "Rotate" psi to eigenvectors
     !
     CALL dgemm_dmat( npw, nbnd, npwx, desc, ONE,  psi, vl, ZERO, psi_t )
     CALL dgemm_dmat( npw, nbnd, npwx, desc, ONE, hpsi, vl, ZERO, hpsi_t )
     if (overlap) CALL dgemm_dmat( npw, nbnd, npwx, desc, ONE, spsi, vl, ZERO, spsi_t )
     !
     psi   = psi_t ; hpsi  = hpsi_t ;  if (overlap) spsi  = spsi_t
     !
     ! Restore current "global" distributed  matrix descriptor
     !
     irc_ip  = irc_ip_store
     nrc_ip  = nrc_ip_store
     rank_ip = rank_ip_store
     !
     DEALLOCATE ( irc_ip_store, nrc_ip_store, rank_ip_store )
     DEALLOCATE(psi_t, hpsi_t) ; if (overlap) DEALLOCATE(spsi_t)
     DEALLOCATE(Hl, Sl)
     DEALLOCATE(vl)
     !
  END SUBROUTINE extract_epairs_dmat
  !
  !
  !
  REAL(DP) FUNCTION get_trace(G, ld, k)
     !
     !  This function returns trace of a k-by-k matrix G
     !
     IMPLICIT NONE
     !
     ! ... I/O variables
     !
     INTEGER,     INTENT (IN) :: ld, k
     REAL(DP),    INTENT (IN) :: G(ld,*)
     !
     ! ... local variables
     !
     INTEGER    :: j
     !
     get_trace = 0.D0
     DO j = 1, k
        get_trace = get_trace + G(j, j)
     END DO
     !
     RETURN
     !
  END FUNCTION get_trace
  !
  !
  !
  SUBROUTINE deallocate_all
    !
    ! This subroutine releases the allocated memory
    !
    IF ( ALLOCATED(hpsi) )    DEALLOCATE ( hpsi )
    IF ( ALLOCATED(spsi) )    DEALLOCATE ( spsi )
    IF ( ALLOCATED(w) )       DEALLOCATE ( w )
    IF ( ALLOCATED(hw) )      DEALLOCATE ( hw )
    IF ( ALLOCATED(sw) )      DEALLOCATE ( sw )
    IF ( ALLOCATED(p) )       DEALLOCATE ( p )
    IF ( ALLOCATED(hp) )      DEALLOCATE ( hp )
    IF ( ALLOCATED(sp) )      DEALLOCATE ( sp )
    IF ( ALLOCATED(K) )       DEALLOCATE ( K )
    IF ( ALLOCATED(M) )       DEALLOCATE ( M )
    IF ( ALLOCATED(K_store) ) DEALLOCATE ( K_store )
    IF ( ALLOCATED(M_store) ) DEALLOCATE ( M_store )
    IF ( ALLOCATED(work) )    DEALLOCATE ( work )
    IF ( ALLOCATED(iwork) )   DEALLOCATE ( iwork )
    IF ( ALLOCATED(irc_ip) )  DEALLOCATE( irc_ip )
    IF ( ALLOCATED(nrc_ip) )  DEALLOCATE( nrc_ip )
    IF ( ALLOCATED(rank_ip) ) DEALLOCATE( rank_ip )
    IF ( ALLOCATED(Gl) )      DEALLOCATE( Gl )
!    IF ( ALLOCATED(G) )       DEALLOCATE( G )
!    IF ( ALLOCATED(Sl) )      DEALLOCATE( Sl )
    !
  END SUBROUTINE deallocate_all
  !
  !
! dmat begin
  SUBROUTINE desc_init( nsiz, desc, irc_ip, nrc_ip )
!    copy-paste from pregterg
     !
     INTEGER, INTENT(IN)  :: nsiz
     TYPE(la_descriptor), INTENT(OUT) :: desc
     INTEGER, INTENT(OUT) :: irc_ip(:)
     INTEGER, INTENT(OUT) :: nrc_ip(:)

     INTEGER :: i, j, rank
     !
     CALL descla_init( desc, nsiz, nsiz, np_ortho, me_ortho, ortho_comm, ortho_cntx, ortho_comm_id)
!     !
!     nx = desc%nrcx   ! nx should be initialized outside whenever needed
     !
     DO j = 0, desc%npc - 1
        CALL descla_local_dims( irc_ip( j + 1 ), nrc_ip( j + 1 ), desc%n, desc%nx, np_ortho(1), j )
        DO i = 0, desc%npr - 1
           CALL GRID2D_RANK( 'R', desc%npr, desc%npc, i, j, rank )
           rank_ip( i+1, j+1 ) = rank * leg_ortho
        END DO
     END DO
     !
     la_proc = .FALSE.
     IF( desc%active_node > 0 ) la_proc = .TRUE.
     !
     RETURN
  END SUBROUTINE desc_init
  !
  !
  SUBROUTINE compute_distmat( dm, desc, v, w, k)
!    Copy-paste from pregterg and desc added as a parameter
     !
     !  This subroutine compute <vi|wj> and store the
     !  result in distributed matrix dm
     !
     IMPLICIT NONE
     !
     ! ... I/O variables
     !
     REAL(DP), INTENT(OUT)   :: dm( :, : )
     TYPE(la_descriptor), INTENT(IN) :: desc
     COMPLEX(DP), INTENT(IN) :: v(:,:), w(:,:)
     INTEGER, INTENT(IN)     :: k
     ! global size of dm = number of vectors in v and w blocks
     !
     ! ... local variables
     !
     INTEGER :: ipc, ipr
     INTEGER :: nr, nc, ir, ic, root
     REAL(DP), ALLOCATABLE :: work( :, : )
     INTEGER :: nx
     ! maximum local block dimension
     !
     nx = desc%nrcx
     !
     ALLOCATE( work( nx, nx ) )
     !
     work = ZERO
     !
     DO ipc = 1, desc%npc !  loop on column procs
        !
        nc = nrc_ip( ipc )
        ic = irc_ip( ipc )
        !
        DO ipr = 1, ipc ! use symmetry for the loop on row procs
           !
           nr = nrc_ip( ipr )
           ir = irc_ip( ipr )
           !
           !  rank of the processor for which this block (ipr,ipc) is destinated
           !
           root = rank_ip( ipr, ipc )

           ! use blas subs. on the matrix block

           CALL DGEMM( 'T','N', nr, nc, npw2, 2.D0, v(1,ir), npwx2, w(1,ic), npwx2, 0.D0, work, nx )

           IF ( gstart == 2 ) &
              CALL DGER( nr, nc, -1.D0, v(1,ir), npwx2, w(1,ic), npwx2, work, nx )
           ! accumulate result on dm of root proc.

           CALL mp_root_sum( work, dm, root, ortho_parent_comm )

        END DO
        !
     END DO
     !
     if (ortho_parent_comm.ne.intra_bgrp_comm .and. nbgrp > 1) dm = dm/nbgrp
     !
!     CALL dsqmsym( nbnd, dm, nx, desc )
     CALL dsqmsym( k, dm, nx, desc )
     !
     DEALLOCATE( work )
     !
     RETURN
  END SUBROUTINE compute_distmat
  !
  !
  SUBROUTINE dgemm_dmat( n, k, ld, desc, alpha, X, Gl, beta, Y  )
!    Copy-paste from refresh_evc in pregterg with some modifications
     !
     ! Compute Y = alpha*(X*G) + beta*Y, where G is distributed across la processor group
     ! and is given by local block Gl.
     !
     IMPLICIT NONE
     !
     ! ... I/O variables
     !
     INTEGER, INTENT(IN) :: n, k, ld
     ! number of rows of X and Y
     ! number of columns of X,Y  and size/leading dimension of (global) G
     ! leading dimension of X and Y
     TYPE(la_descriptor), INTENT(IN) :: desc
     ! descriptor of G
     REAL(DP),    INTENT(IN)      ::  alpha, beta
     COMPLEX(DP), INTENT (IN)     ::  X(ld, k)
     COMPLEX(DP), INTENT (INOUT)  ::  Y(ld, k)
     REAL(DP),    INTENT(IN)      ::  Gl( :, :)
     !
     ! ... local variables
     !
     INTEGER :: ipc, ipr
     INTEGER :: nr, nc, ir, ic, root
     REAL(DP), ALLOCATABLE :: Gltmp( :, : )
     COMPLEX(DP), ALLOCATABLE :: Xtmp( :, : )
     REAL(DP) :: gamm
     INTEGER :: n2, ld2
     INTEGER :: nx
     !
     nx = desc%nrcx
     !
     ALLOCATE( Gltmp( nx, nx ) )
     ALLOCATE( Xtmp( ld, k ) )
     n2  = n*2
     ld2 = ld*2
     !
     DO ipc = 1, desc%npc
        !
        nc = nrc_ip( ipc )
        ic = irc_ip( ipc )
        !
        IF( ic <= k ) THEN
           !
           nc = min( nc, k - ic + 1 )
           !
           gamm = ZERO

           DO ipr = 1, desc%npr
              !
              nr = nrc_ip( ipr )
              ir = irc_ip( ipr )
              !
              root = rank_ip( ipr, ipc )
              IF( ipr-1 == desc%myr .AND. ipc-1 == desc%myc .AND. la_proc ) THEN
                 !
                 !  this proc sends his block
                 !
                 CALL mp_bcast( Gl(:,1:nc), root, ortho_parent_comm )
                 CALL DGEMM( 'N','N', n2, nc, nr, ONE, X(1,ir), ld2, Gl, nx, gamm, Xtmp(1,ic), ld2 )
              ELSE
                 !
                 !  all other procs receive
                 !
                 CALL mp_bcast( Gltmp(:,1:nc), root, ortho_parent_comm )
                 CALL DGEMM( 'N','N', n2, nc, nr, ONE, X(1,ir), ld2, Gltmp, nx, gamm, Xtmp(1,ic), ld2 )
              END IF
              !
              gamm = ONE
              !
           END DO
           !
        END IF
        !
     END DO
     !
     IF (beta /= 0.D0) THEN
        Y = alpha*Xtmp + beta*Y
     ELSE
       Y = alpha*Xtmp
     END IF
     !
     DEALLOCATE( Gltmp )
     DEALLOCATE( Xtmp )
     !
     RETURN
     !
  END SUBROUTINE dgemm_dmat
  !

! dmat end

  SUBROUTINE print_rnrm
     !
     !  Compute the subspce residual
     !
     COMPLEX(DP), ALLOCATABLE :: psi_t(:,:), hpsi_t(:,:), res(:,:)
     REAL(DP), ALLOCATABLE    :: G(:,:), work(:)
     REAL(DP) :: rnrm
     REAL(DP), EXTERNAL       :: DLANGE, DDOT
!ev new begin
integer   :: nwanted, nguard
nguard = 0 ! 24 ! 50
!ev new  end

     rnrm  = 0.D0
!     npw2  = npw*2
!     npwx2 = npwx*2
     ALLOCATE(psi_t(npwx,nbnd), hpsi_t(npwx,nbnd), res(npwx,nbnd))
     ALLOCATE(G(nbnd, nbnd))
     !
!!! EV begin comment
!     psi_t(:,1:nbnd)  = psi(:,1:nbnd)
!     hpsi_t(:,1:nbnd) = hpsi(:,1:nbnd)
!     !
!     !     G = psi_t'hpsi_t
!     CALL DGEMM('T','N', nbnd, nbnd, npw2, 2.D0, psi_t, npwx2, hpsi_t, npwx2, 0.D0, G, nbnd)
!     IF ( gstart == 2 ) CALL DGER( nbnd, nbnd, -1.D0, psi_t, npwx2, hpsi_t, npwx2, G, nbnd )
!     CALL mp_sum( G, intra_bgrp_comm )
!     !
!     !    res = hpsi_t - psi*G
!     res = hpsi_t;
!     CALL DGEMM('N','N',npw2, nbnd, nbnd, -ONE, psi_t, npwx2, G, nbnd, ONE, res, npwx2)
!     !
!     ! ... get the Frobenius norm of the residual
!     rnrm = DLANGE('F', npw2, nbnd, res, npwx2, work)  ! work is not referenced for Frobenius norm
!     rnrm = 2.D0*rnrm**2
!     IF ( gstart == 2 )  rnrm = rnrm - DDOT(nbnd, res, npwx2, res, npwx2)
!!! EV end comment
!!!
!!!
!  EV begin new
!   Instead computing the norm of the whole residual, compute it for X(:,nbnd-nguard)
     nwanted = nbnd - nguard
     psi_t(:,1:nwanted)  = psi(:,1:nwanted)
     hpsi_t(:,1:nwanted) = hpsi(:,1:nwanted)
     !
     !     G = psi_t'hpsi_t
     CALL DGEMM('T','N', nwanted, nwanted, npw2, 2.D0, psi_t, npwx2, hpsi_t, npwx2, 0.D0, G, nbnd)
     IF ( gstart == 2 ) CALL DGER( nwanted, nwanted, -1.D0, psi_t, npwx2, hpsi_t, npwx2, G, nbnd )
     CALL mp_sum( G, intra_bgrp_comm )
     !
     !    res = hpsi_t - psi*G
     res(:,1:nwanted) = hpsi_t(:,1:nwanted);
     CALL DGEMM('N','N',npw2, nwanted, nwanted, -ONE, psi_t, npwx2, G, nbnd, ONE, res, npwx2)
     !
     ! ... get the Frobenius norm of the residual
     rnrm = DLANGE('F', npw2, nwanted, res, npwx2, work)  ! work is not referenced for Frobenius norm
     rnrm = 2.D0*rnrm**2
     IF ( gstart == 2 )  rnrm = rnrm - DDOT(nwanted, res, npwx2, res, npwx2)
!   EV end new

     !
     CALL mp_sum( rnrm, intra_bgrp_comm )
     !
     rnrm = SQRT(ABS(rnrm))
     res_array(iter) = rnrm
     !
     DEALLOCATE(psi_t, hpsi_t, res)
     DEALLOCATE(G)
     !

!     !CALL flush( stdout )
     !
  END SUBROUTINE print_rnrm

!- routines to perform threaded assignements

  SUBROUTINE threaded_assign(array_out, array_in, kdimx, nact, act_idx, bgrp_root_only)
  ! 
  !  assign (copy) a complex array in a threaded way
  !
  !  array_out( 1:kdimx, 1:nact ) = array_in( 1:kdimx, 1:nact )       or
  !
  !  array_out( 1:kdimx, 1:nact ) = array_in( 1:kdimx, act_idx(1:nact) )
  !
  !  if the index array act_idx is given
  !
  !  if  bgrp_root_only is present and .true. the assignement is made only by the 
  !  MPI root process of the bgrp and array_out is zeroed otherwise
  !
  USE util_param,   ONLY : DP
  !
  IMPLICIT NONE
  !
  COMPLEX(DP), INTENT(OUT) :: array_out( kdimx, nact )
  COMPLEX(DP), INTENT(IN)  :: array_in ( kdimx, * )
  INTEGER, INTENT(IN)      :: kdimx, nact
  INTEGER, INTENT(IN), OPTIONAL :: act_idx( * )
  LOGICAL, INTENT(IN), OPTIONAL :: bgrp_root_only
  !
  INTEGER, PARAMETER :: blocksz = 256
  INTEGER :: nblock

  INTEGER :: i, j
  !
  IF (kdimx <=0 .OR. nact<= 0) RETURN
  !
  IF (present(bgrp_root_only) ) THEN
     IF (bgrp_root_only .AND. ( my_bgrp_id /= root_bgrp_id ) ) THEN
        call threaded_memset( array_out, 0.d0, 2*kdimx*nact )
        RETURN
     END IF
  END IF

  nblock = (kdimx - 1)/blocksz  + 1

  IF (present(act_idx) ) THEN
     !$omp parallel do collapse(2)
     DO i=1, nact ; DO j=1,nblock
        array_out(1+(j-1)*blocksz:MIN(j*blocksz,kdimx), i ) = array_in(1+(j-1)*blocksz:MIN(j*blocksz,kdimx), act_idx( i ) ) 
     ENDDO ; ENDDO
     !$omp end parallel do
  ELSE
     !$omp parallel do collapse(2)
     DO i=1, nact ; DO j=1,nblock
        array_out(1+(j-1)*blocksz:MIN(j*blocksz,kdimx), i ) = array_in(1+(j-1)*blocksz:MIN(j*blocksz,kdimx), i ) 
     ENDDO ; ENDDO
     !$omp end parallel do
  END IF
  !
  END SUBROUTINE threaded_assign

END SUBROUTINE ppcg_gamma
