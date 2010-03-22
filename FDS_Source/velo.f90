MODULE VELO

! Module computes the velocity flux terms, baroclinic torque correction terms, and performs the CFL Check

USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS
USE COMP_FUNCTIONS, ONLY: SECOND

IMPLICIT NONE

PRIVATE
CHARACTER(255), PARAMETER :: veloid='$Id$'
CHARACTER(255), PARAMETER :: velorev='$Revision$'
CHARACTER(255), PARAMETER :: velodate='$Date$'

PUBLIC COMPUTE_VELOCITY_FLUX,VELOCITY_PREDICTOR,VELOCITY_CORRECTOR,NO_FLUX,GET_REV_velo, &
       MATCH_VELOCITY,VELOCITY_BC,CHECK_STABILITY
PRIVATE VELOCITY_FLUX,VELOCITY_FLUX_CYLINDRICAL
 
CONTAINS
 
SUBROUTINE COMPUTE_VELOCITY_FLUX(T,NM,FUNCTION_CODE)

REAL(EB), INTENT(IN) :: T
REAL(EB) :: TNOW
INTEGER, INTENT(IN) :: NM,FUNCTION_CODE

IF (SOLID_PHASE_ONLY) RETURN

TNOW = SECOND()

SELECT CASE(FUNCTION_CODE)
   CASE(1)
      IF (PREDICTOR .OR. COMPUTE_VISCOSITY_TWICE) CALL COMPUTE_VISCOSITY(NM)
   CASE(2)
      IF (PREDICTOR .OR. COMPUTE_VISCOSITY_TWICE) CALL VISCOSITY_BC(NM)
      IF (.NOT.CYLINDRICAL) CALL VELOCITY_FLUX(T,NM)
      IF (     CYLINDRICAL) CALL VELOCITY_FLUX_CYLINDRICAL(T,NM)
END SELECT

TUSED(4,NM) = TUSED(4,NM) + SECOND() - TNOW
END SUBROUTINE COMPUTE_VELOCITY_FLUX



SUBROUTINE COMPUTE_VISCOSITY(NM)

! Compute turblent eddy viscosity from constant coefficient Smagorinsky model

USE PHYSICAL_FUNCTIONS, ONLY: GET_VISCOSITY
USE TURBULENCE, ONLY: VARDEN_DYNSMAG
INTEGER, INTENT(IN) :: NM
REAL(EB) :: DUDX,DUDY,DUDZ,DVDX,DVDY,DVDZ,DWDX,DWDY,DWDZ,SS,S12,S13,S23,DELTA,CS,YY_GET(1:N_SPECIES), &
            DAMPING_FACTOR=1._EB,MU_WALL,YPLUS
INTEGER :: I,J,K,ITMP,IIG,JJG,KKG,II,JJ,KK,IW
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL(),RHOP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: YYP=>NULL()
REAL(EB), PARAMETER :: APLUS = 26._EB
 
CALL POINT_TO_MESH(NM)
 
IF (PREDICTOR) THEN
   UU => U
   VV => V
   WW => W
   RHOP => RHO
   IF (N_SPECIES > 0) YYP => YY
   IF ((DYNSMAG .AND. .NOT.EVACUATION_ONLY(NM)) .AND. (ICYC==1 .OR. MOD(ICYC,DSMAG_FREQ)==0)) CALL VARDEN_DYNSMAG(NM)
ELSE
   UU => US
   VV => VS
   WW => WS
   RHOP => RHOS
   IF (N_SPECIES > 0 .AND. .NOT.EVACUATION_ONLY(NM)) YYP => YYS
ENDIF

! Compute viscosity for DNS using primitive species/mixture fraction

!$OMP PARALLEL PRIVATE(CS) SHARED(MU,TMP,YYP)
IF (N_SPECIES == 0 .OR. EVACUATION_ONLY(NM)) THEN
   !$OMP DO COLLAPSE(3) PRIVATE(K,J,I,ITMP)
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            !!$ IF ((K == 1) .AND. (J == 1) .AND. (I == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_COMPUTE_VISCOSITY_01'
            IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
            ITMP = MIN(5000,NINT(TMP(I,J,K)))
            MU(I,J,K)=Y2MU_C(ITMP)*SPECIES(0)%MW
         ENDDO
      ENDDO
   ENDDO
   !$OMP END DO
ELSE
   !$OMP DO COLLAPSE(3) PRIVATE(K,J,I,ITMP,YY_GET) 
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            !!$ IF ((K == 1) .AND. (J == 1) .AND. (I == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_COMPUTE_VISCOSITY_02'
            IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
            ITMP = MIN(5000,NINT(TMP(I,J,K)))
            YY_GET(:) = YYP(I,J,K,:)
            CALL GET_VISCOSITY(YY_GET,MU(I,J,K),ITMP)
         ENDDO
      ENDDO
   ENDDO
   !$OMP END DO
ENDIF

IF (STORE_MU_DNS) THEN
   !$OMP WORKSHARE
   MU_DNS = MU
   !$OMP END WORKSHARE
ENDIF

! Compute eddy viscosity using Smagorinsky model

IF (LES .OR. EVACUATION_ONLY(NM)) THEN
   CS = CSMAG
   IF (EVACUATION_ONLY(NM)) CS = 0.9_EB
   !$OMP DO COLLAPSE(3) PRIVATE(K,J,I,DELTA,DUDX,DVDY,DWDZ,DUDY,DUDZ,DVDX,DVDZ,DWDX,DWDY,S12,S13,S23,SS)
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            !!$ IF ((K == 1) .AND. (J == 1) .AND. (I == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_COMPUTE_VISCOSITY_03'
            IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
            IF (TWO_D) THEN
               DELTA = SQRT(DX(I)*DZ(K))
            ELSE
               DELTA = (DX(I)*DY(J)*DZ(K))**ONTH
            ENDIF
            DUDX = RDX(I)*(UU(I,J,K)-UU(I-1,J,K))
            DVDY = RDY(J)*(VV(I,J,K)-VV(I,J-1,K))
            DWDZ = RDZ(K)*(WW(I,J,K)-WW(I,J,K-1))
            DUDY = 0.25_EB*RDY(J)*(UU(I,J+1,K)-UU(I,J-1,K)+UU(I-1,J+1,K)-UU(I-1,J-1,K))
            DUDZ = 0.25_EB*RDZ(K)*(UU(I,J,K+1)-UU(I,J,K-1)+UU(I-1,J,K+1)-UU(I-1,J,K-1)) 
            DVDX = 0.25_EB*RDX(I)*(VV(I+1,J,K)-VV(I-1,J,K)+VV(I+1,J-1,K)-VV(I-1,J-1,K))
            DVDZ = 0.25_EB*RDZ(K)*(VV(I,J,K+1)-VV(I,J,K-1)+VV(I,J-1,K+1)-VV(I,J-1,K-1))
            DWDX = 0.25_EB*RDX(I)*(WW(I+1,J,K)-WW(I-1,J,K)+WW(I+1,J,K-1)-WW(I-1,J,K-1))
            DWDY = 0.25_EB*RDY(J)*(WW(I,J+1,K)-WW(I,J-1,K)+WW(I,J+1,K-1)-WW(I,J-1,K-1))
            S12 = 0.5_EB*(DUDY+DVDX)
            S13 = 0.5_EB*(DUDZ+DWDX)
            S23 = 0.5_EB*(DVDZ+DWDY)
            SS = SQRT(2._EB*(DUDX**2 + DVDY**2 + DWDZ**2 + 2._EB*(S12**2 + S13**2 + S23**2)))
            
            IF (DYNSMAG) CS = C_DYNSMAG(I,J,K)
            MU(I,J,K) = MU(I,J,K) + RHOP(I,J,K)*(CS*DELTA)**2*SS
         ENDDO
      ENDDO
   ENDDO
   !$OMP END DO
ENDIF

! Mirror viscosity into solids and exterior boundary cells

!$OMP DO PRIVATE(IW,II,JJ,KK,IIG,JJG,KKG,ITMP,MU_WALL)
WALL_LOOP: DO IW=1,NWC
   !!$ IF ((IW == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_VISCOSITY_BC'
   IF (BOUNDARY_TYPE(IW)==NULL_BOUNDARY .OR. BOUNDARY_TYPE(IW)==POROUS_BOUNDARY) CYCLE WALL_LOOP
   II  = IJKW(1,IW)
   JJ  = IJKW(2,IW)
   KK  = IJKW(3,IW)
   IIG = IJKW(6,IW)
   JJG = IJKW(7,IW)
   KKG = IJKW(8,IW)
   
   SELECT CASE(BOUNDARY_TYPE(IW))
      CASE(SOLID_BOUNDARY)
      
         ITMP = MIN(5000,NINT(TMP(IIG,JJG,KKG)))
         MU_WALL = Y2MU_C(ITMP)*SPECIES(0)%MW
         IF (VAN_DRIEST .AND. .NOT.DYNSMAG) THEN
            YPLUS = (0.5_EB/RDN(IW))*U_TAU(IW)*RHOP(IIG,JJG,KKG)/MU_WALL ! should be positive
            DAMPING_FACTOR = (1._EB-EXP(-YPLUS/APLUS))**2
         ENDIF
      
         MU(IIG,JJG,KKG) = MAX(MU_WALL,DAMPING_FACTOR*MU(IIG,JJG,KKG))
         MU(II,JJ,KK) = MU(IIG,JJG,KKG)
      CASE(OPEN_BOUNDARY,MIRROR_BOUNDARY)
         MU(II,JJ,KK) = MU(IIG,JJG,KKG)
         KRES(II,JJ,KK) = KRES(IIG,JJG,KKG)
   END SELECT
ENDDO WALL_LOOP
!$OMP END DO

!$OMP WORKSHARE
MU(   0,0:JBP1,   0) = MU(   1,0:JBP1,1)
MU(IBP1,0:JBP1,   0) = MU(IBAR,0:JBP1,1)
MU(IBP1,0:JBP1,KBP1) = MU(IBAR,0:JBP1,KBAR)
MU(   0,0:JBP1,KBP1) = MU(   1,0:JBP1,KBAR)
MU(0:IBP1,   0,   0) = MU(0:IBP1,   1,1)
MU(0:IBP1,JBP1,0)    = MU(0:IBP1,JBAR,1)
MU(0:IBP1,JBP1,KBP1) = MU(0:IBP1,JBAR,KBAR)
MU(0:IBP1,0,KBP1)    = MU(0:IBP1,   1,KBAR)
MU(0,   0,0:KBP1)    = MU(   1,   1,0:KBP1)
MU(IBP1,0,0:KBP1)    = MU(IBAR,   1,0:KBP1)
MU(IBP1,JBP1,0:KBP1) = MU(IBAR,JBAR,0:KBP1)
MU(0,JBP1,0:KBP1)    = MU(   1,JBAR,0:KBP1)
!$OMP END WORKSHARE

IF (FISHPAK_BC(1)==0) THEN
   !$OMP WORKSHARE
   MU(0,:,:) = MU(IBAR,:,:)
   MU(IBP1,:,:) = MU(1,:,:)
   !$OMP END WORKSHARE
ENDIF
IF (FISHPAK_BC(2)==0) THEN
   !$OMP WORKSHARE
   MU(:,0,:) = MU(:,JBAR,:)
   MU(:,JBP1,:) = MU(:,1,:)
   !$OMP END WORKSHARE
ENDIF
IF (FISHPAK_BC(3)==0) THEN
   !$OMP WORKSHARE
   MU(:,:,0) = MU(:,:,KBAR)
   MU(:,:,KBP1) = MU(:,:,1)
   !$OMP END WORKSHARE
ENDIF
!$OMP END PARALLEL

END SUBROUTINE COMPUTE_VISCOSITY



SUBROUTINE VISCOSITY_BC(NM)

! Specify ghost cell values of the viscosity array MU

INTEGER, INTENT(IN) :: NM
REAL(EB) :: MU_OTHER,DP_OTHER,KRES_OTHER
INTEGER :: IIG,JJG,KKG,II,JJ,KK,IW,IIO,JJO,KKO,NOM,N_INT_CELLS

CALL POINT_TO_MESH(NM)

! Mirror viscosity into solids and exterior boundary cells
 
!$OMP PARALLEL DO PRIVATE(IW,II,JJ,KK,IIG,JJG,KKG,NOM,MU_OTHER,DP_OTHER,KRES_OTHER,KKO,JJO,IIO,N_INT_CELLS)
WALL_LOOP: DO IW=1,NWC
   !!$ IF ((IW == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_VISCOSITY_BC'
   IF (IJKW(9,IW)==0) CYCLE WALL_LOOP
   II  = IJKW(1,IW)
   JJ  = IJKW(2,IW)
   KK  = IJKW(3,IW)
   IIG = IJKW(6,IW)
   JJG = IJKW(7,IW)
   KKG = IJKW(8,IW)
   NOM = IJKW(9,IW)
   MU_OTHER   = 0._EB
   DP_OTHER   = 0._EB
   KRES_OTHER = 0._EB
   DO KKO=IJKW(12,IW),IJKW(15,IW)
      DO JJO=IJKW(11,IW),IJKW(14,IW)
         DO IIO=IJKW(10,IW),IJKW(13,IW)
            MU_OTHER = MU_OTHER + OMESH(NOM)%MU(IIO,JJO,KKO)
            KRES_OTHER = KRES_OTHER + OMESH(NOM)%KRES(IIO,JJO,KKO)
            IF (PREDICTOR) THEN
               DP_OTHER = DP_OTHER + OMESH(NOM)%D(IIO,JJO,KKO)
            ELSE
               DP_OTHER = DP_OTHER + OMESH(NOM)%DS(IIO,JJO,KKO)
            ENDIF
         ENDDO
      ENDDO
   ENDDO
   N_INT_CELLS = (IJKW(13,IW)-IJKW(10,IW)+1) * (IJKW(14,IW)-IJKW(11,IW)+1) * (IJKW(15,IW)-IJKW(12,IW)+1)
   MU_OTHER = MU_OTHER/REAL(N_INT_CELLS,EB)
   KRES_OTHER = KRES_OTHER/REAL(N_INT_CELLS,EB)
   DP_OTHER = DP_OTHER/REAL(N_INT_CELLS,EB)
   MU(II,JJ,KK) = MU_OTHER
   KRES(II,JJ,KK) = KRES_OTHER
   IF (PREDICTOR) THEN
      D(II,JJ,KK) = DP_OTHER
   ELSE
      DS(II,JJ,KK) = DP_OTHER
   ENDIF
ENDDO WALL_LOOP
!$OMP END PARALLEL DO
    
END SUBROUTINE VISCOSITY_BC



SUBROUTINE VELOCITY_FLUX(T,NM)

! Compute convective and diffusive terms of the momentum equations

USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
USE COMPLEX_GEOMETRY, ONLY: INIT_IBM
INTEGER, INTENT(IN) :: NM
REAL(EB) :: T,MUX,MUY,MUZ,UP,UM,VP,VM,WP,WM,VTRM,OMXP,OMXM,OMYP,OMYM,OMZP,OMZM,TXYP,TXYM,TXZP,TXZM,TYZP,TYZM, &
            DTXYDY,DTXZDZ,DTYZDZ,DTXYDX,DTXZDX,DTYZDY, &
            DUDX,DVDY,DWDZ,DUDY,DUDZ,DVDX,DVDZ,DWDX,DWDY, &
            VOMZ,WOMY,UOMY,VOMX,UOMZ,WOMX,PMDT,MPDT, &
            AH,RRHO,GX(0:IBAR_MAX),GY(0:IBAR_MAX),GZ(0:IBAR_MAX),TXXP,TXXM,TYYP,TYYM,TZZP,TZZM,DTXXDX,DTYYDY,DTZZDZ, &
            EPSUP,EPSUM,EPSVP,EPSVM,EPSWP,EPSWM,DUMMY=0._EB, &
            INTEGRAL,SUM_VOLUME,DVOLUME,UMEAN,VMEAN,WMEAN,DU_FORCING,DV_FORCING,DW_FORCING
INTEGER :: I,J,K,IEXP,IEXM,IEYP,IEYM,IEZP,IEZM,IC
REAL(EB), POINTER, DIMENSION(:,:,:) :: TXY=>NULL(),TXZ=>NULL(),TYZ=>NULL(),OMX=>NULL(),OMY=>NULL(),OMZ=>NULL(), &
                                       UU=>NULL(),VV=>NULL(),WW=>NULL(),RHOP=>NULL(),DP=>NULL()
 
CALL POINT_TO_MESH(NM)
 
IF (PREDICTOR) THEN
   UU => U
   VV => V
   WW => W
   DP => D  
   RHOP => RHO
ELSE
   UU => US
   VV => VS
   WW => WS
   DP => DS
   RHOP => RHOS
ENDIF

TXY => WORK1
TXZ => WORK2
TYZ => WORK3
OMX => WORK4
OMY => WORK5
OMZ => WORK6

! Mean forcing

IF (MEAN_FORCING) THEN

   INTEGRAL = 0._EB
   SUM_VOLUME = 0._EB
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=0,IBAR
            DVOLUME = DXN(I)*DY(J)*DZ(K)
            INTEGRAL = INTEGRAL + UU(I,J,K)*DVOLUME
            SUM_VOLUME = SUM_VOLUME + DVOLUME
         ENDDO
      ENDDO
   ENDDO
   UMEAN = INTEGRAL/SUM_VOLUME
   
   INTEGRAL = 0._EB
   SUM_VOLUME = 0._EB
   DO K=1,KBAR
      DO J=0,JBAR
         DO I=1,IBAR
            DVOLUME = DX(I)*DYN(J)*DZ(K)
            INTEGRAL = INTEGRAL + VV(I,J,K)*DVOLUME
            SUM_VOLUME = SUM_VOLUME + DVOLUME
         ENDDO
      ENDDO
   ENDDO
   VMEAN = INTEGRAL/SUM_VOLUME
   
   INTEGRAL = 0._EB
   SUM_VOLUME = 0._EB
   DO K=0,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            DVOLUME = DX(I)*DY(J)*DZN(K)
            INTEGRAL = INTEGRAL + WW(I,J,K)*DVOLUME
            SUM_VOLUME = SUM_VOLUME + DVOLUME
         ENDDO
      ENDDO
   ENDDO
   WMEAN = INTEGRAL/SUM_VOLUME
   
   DU_FORCING = RFAC_FORCING*(U0-UMEAN)/DT
   DV_FORCING = RFAC_FORCING*(V0-VMEAN)/DT
   DW_FORCING = RFAC_FORCING*(W0-WMEAN)/DT
ELSE
   DU_FORCING = 0._EB
   DV_FORCING = 0._EB
   DW_FORCING = 0._EB
ENDIF


! Compute vorticity and stress tensor components

!$OMP PARALLEL
!$OMP DO COLLAPSE(3) PRIVATE(K,J,I,DUDY,DVDX,DUDZ,DWDX,DVDZ,DWDY,MUX,MUY,MUZ)
DO K=0,KBAR
   DO J=0,JBAR
      DO I=0,IBAR
         !!$ IF ((K == 1) .AND. (J == 1) .AND. (I == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_VELOCITY_FLUX_01'
         DUDY = RDYN(J)*(UU(I,J+1,K)-UU(I,J,K))
         DVDX = RDXN(I)*(VV(I+1,J,K)-VV(I,J,K))
         DUDZ = RDZN(K)*(UU(I,J,K+1)-UU(I,J,K))
         DWDX = RDXN(I)*(WW(I+1,J,K)-WW(I,J,K))
         DVDZ = RDZN(K)*(VV(I,J,K+1)-VV(I,J,K))
         DWDY = RDYN(J)*(WW(I,J+1,K)-WW(I,J,K))
         OMX(I,J,K) = DWDY - DVDZ
         OMY(I,J,K) = DUDZ - DWDX
         OMZ(I,J,K) = DVDX - DUDY
         MUX = 0.25_EB*(MU(I,J+1,K)+MU(I,J,K)+MU(I,J,K+1)+MU(I,J+1,K+1))
         MUY = 0.25_EB*(MU(I+1,J,K)+MU(I,J,K)+MU(I,J,K+1)+MU(I+1,J,K+1))
         MUZ = 0.25_EB*(MU(I+1,J,K)+MU(I,J,K)+MU(I,J+1,K)+MU(I+1,J+1,K))
         TXY(I,J,K) = MUZ*(DVDX + DUDY)
         TXZ(I,J,K) = MUY*(DUDZ + DWDX)
         TYZ(I,J,K) = MUX*(DVDZ + DWDY)
         
         IF (IMMERSED_BOUNDARY_METHOD==2) THEN
            IBM_SAVE1(I,J,K) = DUDZ
            IBM_SAVE2(I,J,K) = DWDX
         ENDIF
         
      ENDDO
   ENDDO
ENDDO
!$OMP END DO NOWAIT

! Compute gravity components

!$OMP SINGLE PRIVATE(I)
IF (.NOT.SPATIAL_GRAVITY_VARIATION) THEN
   GX(0:IBAR) = EVALUATE_RAMP(T,DUMMY,I_RAMP_GX)*GVEC(1)
   GY(0:IBAR) = EVALUATE_RAMP(T,DUMMY,I_RAMP_GY)*GVEC(2)
   GZ(0:IBAR) = EVALUATE_RAMP(T,DUMMY,I_RAMP_GZ)*GVEC(3)
ELSE
   DO I=0,IBAR
      GX(I) = EVALUATE_RAMP(X(I),DUMMY,I_RAMP_GX)*GVEC(1)
      GY(I) = EVALUATE_RAMP(X(I),DUMMY,I_RAMP_GY)*GVEC(2)
      GZ(I) = EVALUATE_RAMP(X(I),DUMMY,I_RAMP_GZ)*GVEC(3)
   ENDDO
ENDIF
 
! Upwind/Downwind bias factors
 
IF (PREDICTOR) THEN
   PMDT =  0.5_EB*DT
   MPDT = -0.5_EB*DT
ELSE
   PMDT = -0.5_EB*DT
   MPDT =  0.5_EB*DT
ENDIF
!$OMP END SINGLE

IF (NOBIAS) THEN
   PMDT = 0._EB
   MPDT = 0._EB
ENDIF
 
! Compute x-direction flux term FVX

!$OMP DO COLLAPSE(3) &
!$OMP PRIVATE(K,J,I,WP,WM,VP,VM,EPSWP,EPSWM,EPSVP,EPSVM,OMYP,OMYM,OMZP,OMZM,TXZP,TXZM,TXYP,TXYM,IC,IEYP,IEYM,IEZP,IEZM) &
!$OMP PRIVATE(WOMY,VOMZ,RRHO,AH,DVDY,DWDZ,TXXP,TXXM,DTXXDX,DTXYDY,DTXZDZ,VTRM)
DO K=1,KBAR
   DO J=1,JBAR
      DO I=0,IBAR
         !!$ IF ((K == 1) .AND. (J == 1) .AND. (I == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_VELOCITY_FLUX_03'
         WP    = WW(I,J,K)   + WW(I+1,J,K)
         WM    = WW(I,J,K-1) + WW(I+1,J,K-1)
         VP    = VV(I,J,K)   + VV(I+1,J,K)
         VM    = VV(I,J-1,K) + VV(I+1,J-1,K)
         EPSWP = 1._EB + WP*MPDT*RDZN(K)
         EPSWM = 1._EB + WM*PMDT*RDZN(K-1)
         EPSVP = 1._EB + VP*MPDT*RDYN(J)
         EPSVM = 1._EB + VM*PMDT*RDYN(J-1)
         OMYP  = OMY(I,J,K)
         OMYM  = OMY(I,J,K-1)
         OMZP  = OMZ(I,J,K)
         OMZM  = OMZ(I,J-1,K)
         TXZP  = TXZ(I,J,K)
         TXZM  = TXZ(I,J,K-1)
         TXYP  = TXY(I,J,K)
         TXYM  = TXY(I,J-1,K)
         IC    = CELL_INDEX(I,J,K)
         IEYP  = EDGE_INDEX(IC,8)
         IEYM  = EDGE_INDEX(IC,6)
         IEZP  = EDGE_INDEX(IC,12)
         IEZM  = EDGE_INDEX(IC,10)
         IF (OME_E(IEYP,-1)>-1.E5_EB) OMYP = OME_E(IEYP,-1)
         IF (OME_E(IEYM, 1)>-1.E5_EB) OMYM = OME_E(IEYM, 1)
         IF (OME_E(IEZP,-2)>-1.E5_EB) OMZP = OME_E(IEZP,-2)
         IF (OME_E(IEZM, 2)>-1.E5_EB) OMZM = OME_E(IEZM, 2)
         IF (TAU_E(IEYP,-1)>-1.E5_EB) TXZP = TAU_E(IEYP,-1)
         IF (TAU_E(IEYM, 1)>-1.E5_EB) TXZM = TAU_E(IEYM, 1)
         IF (TAU_E(IEZP,-2)>-1.E5_EB) TXYP = TAU_E(IEZP,-2)
         IF (TAU_E(IEZM, 2)>-1.E5_EB) TXYM = TAU_E(IEZM, 2)
         WOMY  = EPSWP*WP*OMYP + EPSWM*WM*OMYM
         VOMZ  = EPSVP*VP*OMZP + EPSVM*VM*OMZM
         RRHO  = 2._EB/(RHOP(I,J,K)+RHOP(I+1,J,K))
         AH    = RHO_0(K)*RRHO - 1._EB   
         DVDY  = (VV(I+1,J,K)-VV(I+1,J-1,K))*RDY(J)
         DWDZ  = (WW(I+1,J,K)-WW(I+1,J,K-1))*RDZ(K)
         TXXP  = MU(I+1,J,K)*( FOTH*DP(I+1,J,K) - 2._EB*(DVDY+DWDZ) )
         DVDY  = (VV(I,J,K)-VV(I,J-1,K))*RDY(J)
         DWDZ  = (WW(I,J,K)-WW(I,J,K-1))*RDZ(K)
         TXXM  = MU(I,J,K)  *( FOTH*DP(I,J,K)   - 2._EB*(DVDY+DWDZ) )
         DTXXDX= RDXN(I)*(TXXP-TXXM)
         DTXYDY= RDY(J) *(TXYP-TXYM)
         DTXZDZ= RDZ(K) *(TXZP-TXZM)
         VTRM  = RRHO*(DTXXDX + DTXYDY + DTXZDZ)
         FVX(I,J,K) = 0.25_EB*(WOMY - VOMZ) + GX(I)*AH - VTRM - RRHO*FVEC(1) - DU_FORCING
      ENDDO 
   ENDDO   
ENDDO
!$OMP END DO NOWAIT
 
! Compute y-direction flux term FVY

!$OMP DO COLLAPSE(3) &
!$OMP PRIVATE(K,J,I,UP,UM,WP,WM,EPSUP,EPSUM,EPSWP,EPSWM,OMXP,OMXM,OMZP,OMZM,TYZP,TYZM,TXYP,TXYM,IC,IEXP,IEXM,IEZP,IEZM) &
!$OMP PRIVATE(WOMX,UOMZ,RRHO,AH,DUDX,DWDZ,TYYP,TYYM,DTXYDX,DTYYDY,DTYZDZ,VTRM)
DO K=1,KBAR
   DO J=0,JBAR
      DO I=1,IBAR
         UP    = UU(I,J,K)   + UU(I,J+1,K)
         UM    = UU(I-1,J,K) + UU(I-1,J+1,K)
         WP    = WW(I,J,K)   + WW(I,J+1,K)
         WM    = WW(I,J,K-1) + WW(I,J+1,K-1)
         EPSUP = 1._EB + UP*MPDT*RDXN(I)
         EPSUM = 1._EB + UM*PMDT*RDXN(I-1)
         EPSWP = 1._EB + WP*MPDT*RDZN(K)
         EPSWM = 1._EB + WM*PMDT*RDZN(K-1)
         OMXP  = OMX(I,J,K)
         OMXM  = OMX(I,J,K-1)
         OMZP  = OMZ(I,J,K)
         OMZM  = OMZ(I-1,J,K)
         TYZP  = TYZ(I,J,K)
         TYZM  = TYZ(I,J,K-1)
         TXYP  = TXY(I,J,K)
         TXYM  = TXY(I-1,J,K)
         IC    = CELL_INDEX(I,J,K)
         IEXP  = EDGE_INDEX(IC,4)
         IEXM  = EDGE_INDEX(IC,2)
         IEZP  = EDGE_INDEX(IC,12)
         IEZM  = EDGE_INDEX(IC,11)
         IF (OME_E(IEXP,-2)>-1.E5_EB) OMXP = OME_E(IEXP,-2)
         IF (OME_E(IEXM, 2)>-1.E5_EB) OMXM = OME_E(IEXM, 2)
         IF (OME_E(IEZP,-1)>-1.E5_EB) OMZP = OME_E(IEZP,-1)
         IF (OME_E(IEZM, 1)>-1.E5_EB) OMZM = OME_E(IEZM, 1)
         IF (TAU_E(IEXP,-2)>-1.E5_EB) TYZP = TAU_E(IEXP,-2)
         IF (TAU_E(IEXM, 2)>-1.E5_EB) TYZM = TAU_E(IEXM, 2)
         IF (TAU_E(IEZP,-1)>-1.E5_EB) TXYP = TAU_E(IEZP,-1)
         IF (TAU_E(IEZM, 1)>-1.E5_EB) TXYM = TAU_E(IEZM, 1)
         WOMX  = EPSWP*WP*OMXP + EPSWM*WM*OMXM
         UOMZ  = EPSUP*UP*OMZP + EPSUM*UM*OMZM
         RRHO  = 2._EB/(RHOP(I,J,K)+RHOP(I,J+1,K))
         AH    = RHO_0(K)*RRHO - 1._EB
         DUDX  = (UU(I,J+1,K)-UU(I-1,J+1,K))*RDX(I)
         DWDZ  = (WW(I,J+1,K)-WW(I,J+1,K-1))*RDZ(K)
         TYYP  = MU(I,J+1,K)*( FOTH*DP(I,J+1,K) - 2._EB*(DUDX+DWDZ) )
         DUDX  = (UU(I,J,K)-UU(I-1,J,K))*RDX(I)
         DWDZ  = (WW(I,J,K)-WW(I,J,K-1))*RDZ(K)
         TYYM  = MU(I,J,K)  *( FOTH*DP(I,J,K)   - 2._EB*(DUDX+DWDZ) )
         DTXYDX= RDX(I) *(TXYP-TXYM)
         DTYYDY= RDYN(J)*(TYYP-TYYM)
         DTYZDZ= RDZ(K) *(TYZP-TYZM)
         VTRM  = RRHO*(DTXYDX + DTYYDY + DTYZDZ)
         FVY(I,J,K) = 0.25_EB*(UOMZ - WOMX) + GY(I)*AH - VTRM - RRHO*FVEC(2) - DV_FORCING
      ENDDO
   ENDDO   
ENDDO
!$OMP END DO NOWAIT
 
! Compute z-direction flux term FVZ

!$OMP DO COLLAPSE(3) &
!$OMP PRIVATE(K,J,I,UP,UM,VP,VM,EPSUP,EPSUM,EPSVP,EPSVM,OMYP,OMYM,OMXP,OMXM,TXZP,TXZM,TYZP,TYZM,IC,IEXP,IEXM,IEYP,IEYM) &
!$OMP PRIVATE(UOMY,VOMX,RRHO,AH,DUDX,DVDY,TZZP,TZZM,DTXZDX,DTYZDY,DTZZDZ,VTRM) 
DO K=0,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         UP    = UU(I,J,K)   + UU(I,J,K+1)
         UM    = UU(I-1,J,K) + UU(I-1,J,K+1)
         VP    = VV(I,J,K)   + VV(I,J,K+1)
         VM    = VV(I,J-1,K) + VV(I,J-1,K+1)
         EPSUP = 1._EB + UP*MPDT*RDXN(I)
         EPSUM = 1._EB + UM*PMDT*RDXN(I-1)
         EPSVP = 1._EB + VP*MPDT*RDYN(J)
         EPSVM = 1._EB + VM*PMDT*RDYN(J-1)
         OMYP  = OMY(I,J,K)
         OMYM  = OMY(I-1,J,K)
         OMXP  = OMX(I,J,K)
         OMXM  = OMX(I,J-1,K)
         TXZP  = TXZ(I,J,K)
         TXZM  = TXZ(I-1,J,K)
         TYZP  = TYZ(I,J,K)
         TYZM  = TYZ(I,J-1,K)
         IC    = CELL_INDEX(I,J,K)
         IEXP  = EDGE_INDEX(IC,4)
         IEXM  = EDGE_INDEX(IC,3)
         IEYP  = EDGE_INDEX(IC,8)
         IEYM  = EDGE_INDEX(IC,7)
         IF (OME_E(IEXP,-1)>-1.E5_EB) OMXP = OME_E(IEXP,-1)
         IF (OME_E(IEXM, 1)>-1.E5_EB) OMXM = OME_E(IEXM, 1)
         IF (OME_E(IEYP,-2)>-1.E5_EB) OMYP = OME_E(IEYP,-2)
         IF (OME_E(IEYM, 2)>-1.E5_EB) OMYM = OME_E(IEYM, 2)
         IF (TAU_E(IEXP,-1)>-1.E5_EB) TYZP = TAU_E(IEXP,-1)
         IF (TAU_E(IEXM, 1)>-1.E5_EB) TYZM = TAU_E(IEXM, 1)
         IF (TAU_E(IEYP,-2)>-1.E5_EB) TXZP = TAU_E(IEYP,-2)
         IF (TAU_E(IEYM, 2)>-1.E5_EB) TXZM = TAU_E(IEYM, 2)
         UOMY  = EPSUP*UP*OMYP + EPSUM*UM*OMYM
         VOMX  = EPSVP*VP*OMXP + EPSVM*VM*OMXM
         RRHO  = 2._EB/(RHOP(I,J,K)+RHOP(I,J,K+1))
         AH    = 0.5_EB*(RHO_0(K)+RHO_0(K+1))*RRHO - 1._EB
         DUDX  = (UU(I,J,K+1)-UU(I-1,J,K+1))*RDX(I)
         DVDY  = (VV(I,J,K+1)-VV(I,J-1,K+1))*RDY(J)
         TZZP  = MU(I,J,K+1)*( FOTH*DP(I,J,K+1) - 2._EB*(DUDX+DVDY) )
         DUDX  = (UU(I,J,K)-UU(I-1,J,K))*RDX(I)
         DVDY  = (VV(I,J,K)-VV(I,J-1,K))*RDY(J)
         TZZM  = MU(I,J,K)  *( FOTH*DP(I,J,K)   - 2._EB*(DUDX+DVDY) )
         DTXZDX= RDX(I) *(TXZP-TXZM)
         DTYZDY= RDY(J) *(TYZP-TYZM)
         DTZZDZ= RDZN(K)*(TZZP-TZZM)
         VTRM  = RRHO*(DTXZDX + DTYZDY + DTZZDZ)
         FVZ(I,J,K) = 0.25_EB*(VOMX - UOMY) + GZ(I)*AH - VTRM - RRHO*FVEC(3) - DW_FORCING     
      ENDDO
   ENDDO   
ENDDO
!$OMP END DO NOWAIT
!$OMP END PARALLEL
 
! Baroclinic torque correction
 
IF (BAROCLINIC .AND. .NOT.EVACUATION_ONLY(NM)) CALL BAROCLINIC_CORRECTION

! Adjust FVX, FVY and FVZ at solid, internal obstructions for no flux

CALL NO_FLUX(NM)
IF (IMMERSED_BOUNDARY_METHOD>=0) THEN
   CALL INIT_IBM(T,NM)
   CALL IBM_VELOCITY_FLUX(NM)
ENDIF
IF (EVACUATION_ONLY(NM)) FVZ = 0._EB

END SUBROUTINE VELOCITY_FLUX



SUBROUTINE VELOCITY_FLUX_CYLINDRICAL(T,NM)

! Compute convective and diffusive terms for 2D axisymmetric

USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP 
REAL(EB) :: T,DMUDX
INTEGER :: I0
INTEGER, INTENT(IN) :: NM
REAL(EB) :: MUY,UP,UM,WP,WM,VTRM,DTXZDZ,DTXZDX,DUDX,DWDZ,DUDZ,DWDX,WOMY,UOMY,PMDT,MPDT,OMYP,OMYM,TXZP,TXZM, &
            AH,RRHO,GX,GZ,TXXP,TXXM,TZZP,TZZM,DTXXDX,DTZZDZ,EPSUP,EPSUM,EPSWP,EPSWM,DUMMY=0._EB
INTEGER :: I,J,K,IEYP,IEYM,IC
REAL(EB), POINTER, DIMENSION(:,:,:) :: TXZ=>NULL(),OMY=>NULL(),UU=>NULL(),WW=>NULL(),RHOP=>NULL(),DP=>NULL()
 
CALL POINT_TO_MESH(NM)
 
IF (PREDICTOR) THEN
   UU => U
   WW => W
   DP => D  
   RHOP => RHO
ELSE
   UU => US
   WW => WS
   DP => DS
   RHOP => RHOS
ENDIF
 
TXZ => WORK2
OMY => WORK5
 
! Compute vorticity and stress tensor components

!$OMP PARALLEL
!$OMP DO COLLAPSE(3) PRIVATE(K,J,I,DUDZ,DWDX,MUY)  
DO K=0,KBAR
   DO J=0,JBAR
      DO I=0,IBAR
         !!$ IF ((K == 1) .AND. (J == 1) .AND. (I == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_FLUX_CYLINDRICAL_01'
         DUDZ = RDZN(K)*(UU(I,J,K+1)-UU(I,J,K))
         DWDX = RDXN(I)*(WW(I+1,J,K)-WW(I,J,K))
         OMY(I,J,K) = DUDZ - DWDX
         MUY = 0.25_EB*(MU(I+1,J,K)+MU(I,J,K)+MU(I,J,K+1)+MU(I+1,J,K+1))
         TXZ(I,J,K) = MUY*(DUDZ + DWDX)
      ENDDO
   ENDDO
ENDDO
!$OMP END DO NOWAIT
 
! Compute gravity components

!$OMP SINGLE
GX  = 0._EB
GZ  = EVALUATE_RAMP(T,DUMMY,I_RAMP_GZ)*GVEC(3)
 
! Upwind/Downwind bias factors
 
IF (PREDICTOR) THEN
   PMDT =  0.5_EB*DT
   MPDT = -0.5_EB*DT
ELSE
   PMDT = -0.5_EB*DT
   MPDT =  0.5_EB*DT
ENDIF

IF (NOBIAS) THEN
   PMDT = 0._EB
   MPDT = 0._EB
ENDIF
 
! Compute r-direction flux term FVX
 
IF (XS==0) THEN 
   I0 = 1
ELSE
   I0 = 0
ENDIF
 
J = 1
!$OMP END SINGLE


!$OMP DO COLLAPSE(2) &
!$OMP PRIVATE(K,I,WP,WM,EPSWP,EPSWM,OMYP,OMYM,TXZP,TXZM,IC,IEYP,IEYM,WOMY,RRHO,AH,DWDZ,TXXP,TXXM,DTXXDX,DTXZDZ,DMUDX,VTRM) 
DO K= 1,KBAR
   DO I=I0,IBAR
      !!$ IF ((K == 1) .AND. (I == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_FLUX_CYLINDRICAL_03' 
      WP    = WW(I,J,K)   + WW(I+1,J,K)
      WM    = WW(I,J,K-1) + WW(I+1,J,K-1)
      EPSWP = 1._EB + WP*MPDT*RDZN(K)
      EPSWM = 1._EB + WM*PMDT*RDZN(K-1)
      OMYP  = OMY(I,J,K)
      OMYM  = OMY(I,J,K-1)
      TXZP  = TXZ(I,J,K)
      TXZM  = TXZ(I,J,K-1)
      IC    = CELL_INDEX(I,J,K)
      IEYP  = EDGE_INDEX(IC,8)
      IEYM  = EDGE_INDEX(IC,6)
      IF (OME_E(IEYP,-1)>-1.E5_EB) OMYP = OME_E(IEYP,-1)
      IF (OME_E(IEYM, 1)>-1.E5_EB) OMYM = OME_E(IEYM, 1)
      IF (TAU_E(IEYP,-1)>-1.E5_EB) TXZP = TAU_E(IEYP,-1)
      IF (TAU_E(IEYM, 1)>-1.E5_EB) TXZM = TAU_E(IEYM, 1)
      WOMY  = EPSWP*WP*OMYP + EPSWM*WM*OMYM
      RRHO  = 2._EB/(RHOP(I,J,K)+RHOP(I+1,J,K))
      AH    = RHO_0(K)*RRHO - 1._EB   
      DWDZ  = (WW(I+1,J,K)-WW(I+1,J,K-1))*RDZ(K)
      TXXP  = MU(I+1,J,K)*( FOTH*DP(I+1,J,K) - 2._EB*DWDZ )
      DWDZ  = (WW(I,J,K)-WW(I,J,K-1))*RDZ(K)
      TXXM  = MU(I,J,K)  *( FOTH*DP(I,J,K) -2._EB*DWDZ )
      DTXXDX= RDXN(I)*(TXXP-TXXM)
      DTXZDZ= RDZ(K) *(TXZP-TXZM)
      DMUDX = (MU(I+1,J,K)-MU(I,J,K))*RDXN(I)
      VTRM  = RRHO*( DTXXDX + DTXZDZ - 2._EB*UU(I,J,K)*DMUDX/R(I) ) 
      FVX(I,J,K) = 0.25_EB*WOMY + GX*AH - VTRM 
   ENDDO
ENDDO
!$OMP END DO NOWAIT
! Compute z-direction flux term FVZ
 
!J = 1 !not needed, J = 1 is declared before FVX-calculation

!$OMP DO COLLAPSE(2) &
!$OMP PRIVATE(K,I,UP,UM,EPSUP,EPSUM,OMYP,OMYM,TXZP,TXZM,IC,IEYP,IEYM,UOMY,RRHO,AH,DUDX,TZZP,TZZM,DTXZDX,DTZZDZ,VTRM)
DO K=0,KBAR
   DO I=1,IBAR
      UP    = UU(I,J,K)   + UU(I,J,K+1)
      UM    = UU(I-1,J,K) + UU(I-1,J,K+1)
      EPSUP = 1._EB + UP*MPDT*RDXN(I)
      EPSUM = 1._EB + UM*PMDT*RDXN(I-1)
      OMYP  = OMY(I,J,K)
      OMYM  = OMY(I-1,J,K)
      TXZP  = TXZ(I,J,K)
      TXZM  = TXZ(I-1,J,K)
      IC    = CELL_INDEX(I,J,K)
      IEYP  = EDGE_INDEX(IC,8)
      IEYM  = EDGE_INDEX(IC,7)
      IF (OME_E(IEYP,-2)>-1.E5_EB) OMYP = OME_E(IEYP,-2)
      IF (OME_E(IEYM, 2)>-1.E5_EB) OMYM = OME_E(IEYM, 2)
      IF (TAU_E(IEYP,-2)>-1.E5_EB) TXZP = TAU_E(IEYP,-2)
      IF (TAU_E(IEYM, 2)>-1.E5_EB) TXZM = TAU_E(IEYM, 2)
      UOMY  = EPSUP*UP*OMYP + EPSUM*UM*OMYM
      RRHO  = 2._EB/(RHOP(I,J,K)+RHOP(I,J,K+1))
      AH    = 0.5_EB*(RHO_0(K)+RHO_0(K+1))*RRHO - 1._EB
      DUDX  = (R(I)*UU(I,J,K+1)-R(I-1)*UU(I-1,J,K+1))*RDX(I)*RRN(I)
      TZZP  = MU(I,J,K+1)*( FOTH*DP(I,J,K+1) - 2._EB*DUDX )
      DUDX  = (R(I)*UU(I,J,K)-R(I-1)*UU(I-1,J,K))*RDX(I)*RRN(I)
      TZZM  = MU(I,J,K)  *( FOTH*DP(I,J,K)   - 2._EB*DUDX )
      DTXZDX= RDX(I) *(R(I)*TXZP-R(I-1)*TXZM)*RRN(I)
      DTZZDZ= RDZN(K)*(     TZZP       -TZZM)
      VTRM  = RRHO*(DTXZDX + DTZZDZ)
      FVZ(I,J,K) = -0.25_EB*UOMY + GZ*AH - VTRM 
   ENDDO
ENDDO
!$OMP END DO
!$OMP END PARALLEL   
 
! Baroclinic torque correction terms
 
IF (BAROCLINIC) CALL BAROCLINIC_CORRECTION
 
! Adjust FVX and FVZ at solid, internal obstructions for no flux
 
CALL NO_FLUX(NM)
 
END SUBROUTINE VELOCITY_FLUX_CYLINDRICAL
 
 
SUBROUTINE NO_FLUX(NM)

! Set FVX,FVY,FVZ inside and on the surface of solid obstructions to maintain no flux

USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP 
INTEGER, INTENT(IN) :: NM
REAL(EB), POINTER, DIMENSION(:,:,:) :: HP=>NULL()
REAL(EB) :: RFODT,H_OTHER,DUUDT,DVVDT,DWWDT
INTEGER  :: IC2,IC1,N,I,J,K,IW,II,JJ,KK,IOR,N_INT_CELLS,IIO,JJO,KKO,NOM
TYPE (OBSTRUCTION_TYPE), POINTER :: OB=>NULL()

CALL POINT_TO_MESH(NM)
 
RFODT = RELAXATION_FACTOR/DT

IF (PREDICTOR) HP => H
IF (CORRECTOR) HP => HS
 
! Exchange H at interpolated boundaries

!$OMP PARALLEL
!$OMP DO PRIVATE(IW,NOM,II,JJ,KK,H_OTHER,KKO,JJO,IIO,N_INT_CELLS)
DO IW=1,NEWC
   !!$ IF ((IW == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_NO_FLUX_01'
   NOM = IJKW(9,IW)
   IF (NOM==0) CYCLE
   II = IJKW(1,IW)
   JJ = IJKW(2,IW)
   KK = IJKW(3,IW)   
   H_OTHER = 0._EB
   DO KKO=IJKW(12,IW),IJKW(15,IW)
      DO JJO=IJKW(11,IW),IJKW(14,IW)
         DO IIO=IJKW(10,IW),IJKW(13,IW)
            IF (PREDICTOR) H_OTHER = H_OTHER + OMESH(NOM)%H(IIO,JJO,KKO)
            IF (CORRECTOR) H_OTHER = H_OTHER + OMESH(NOM)%HS(IIO,JJO,KKO)
         ENDDO
      ENDDO
   ENDDO
   N_INT_CELLS = (IJKW(13,IW)-IJKW(10,IW)+1) * (IJKW(14,IW)-IJKW(11,IW)+1) * (IJKW(15,IW)-IJKW(12,IW)+1)
   IF (PREDICTOR) H(II,JJ,KK)  = H_OTHER/REAL(N_INT_CELLS,EB)
   IF (CORRECTOR) HS(II,JJ,KK) = H_OTHER/REAL(N_INT_CELLS,EB)
ENDDO
!$OMP END DO

! Set FVX, FVY and FVZ to drive velocity components at solid boundaries towards zero

!$OMP DO PRIVATE(N,OB,K,J,I,IC1,IC2,DUUDT,DVVDT,DWWDT) 
OBST_LOOP: DO N=1,N_OBST
   !!$ IF ((N == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_NO_FLUX_02'
   OB=>OBSTRUCTION(N)
   DO K=OB%K1+1,OB%K2
      DO J=OB%J1+1,OB%J2
         LOOP1: DO I=OB%I1  ,OB%I2
            IC1 = CELL_INDEX(I,J,K)
            IC2 = CELL_INDEX(I+1,J,K)
            IF (SOLID(IC1) .AND. SOLID(IC2)) THEN
               IF (PREDICTOR) DUUDT = -RFODT*U(I,J,K)
               IF (CORRECTOR) DUUDT = -RFODT*(U(I,J,K)+US(I,J,K))
               FVX(I,J,K) = -RDXN(I)*(HP(I+1,J,K)-HP(I,J,K)) - DUUDT
            ENDIF
         ENDDO LOOP1
      ENDDO 
   ENDDO 
   DO K=OB%K1+1,OB%K2
      DO J=OB%J1  ,OB%J2
         LOOP2: DO I=OB%I1+1,OB%I2
            IC1 = CELL_INDEX(I,J,K)
            IC2 = CELL_INDEX(I,J+1,K)
            IF (SOLID(IC1) .AND. SOLID(IC2)) THEN
               IF (PREDICTOR) DVVDT = -RFODT*V(I,J,K)
               IF (CORRECTOR) DVVDT = -RFODT*(V(I,J,K)+VS(I,J,K))
               FVY(I,J,K) = -RDYN(J)*(HP(I,J+1,K)-HP(I,J,K)) - DVVDT
            ENDIF
         ENDDO LOOP2
      ENDDO 
   ENDDO 
   DO K=OB%K1  ,OB%K2
      DO J=OB%J1+1,OB%J2
         LOOP3: DO I=OB%I1+1,OB%I2
            IC1 = CELL_INDEX(I,J,K)
            IC2 = CELL_INDEX(I,J,K+1)
            IF (SOLID(IC1) .AND. SOLID(IC2)) THEN
               IF (PREDICTOR) DWWDT = -RFODT*W(I,J,K)
               IF (CORRECTOR) DWWDT = -RFODT*(W(I,J,K)+WS(I,J,K))
               FVZ(I,J,K) = -RDZN(K)*(HP(I,J,K+1)-HP(I,J,K)) - DWWDT
            ENDIF
         ENDDO LOOP3
      ENDDO 
   ENDDO 
ENDDO OBST_LOOP
!$OMP END DO
 
! Add normal velocity to FVX, etc. for surface cells

!$OMP DO PRIVATE(IW,NOM,II,JJ,KK,IOR,DUUDT,DVVDT,DWWDT) 
WALL_LOOP: DO IW=1,NWC
!!$ IF ((IW == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_NO_FLUX_03' 
   IF (BOUNDARY_TYPE(IW)==OPEN_BOUNDARY)         CYCLE WALL_LOOP
   IF (BOUNDARY_TYPE(IW)==INTERPOLATED_BOUNDARY) CYCLE WALL_LOOP
   NOM = IJKW(9,IW)
   IF (BOUNDARY_TYPE(IW)==NULL_BOUNDARY .AND. NOM==0) CYCLE WALL_LOOP

   II  = IJKW(1,IW)
   JJ  = IJKW(2,IW)
   KK  = IJKW(3,IW)
   IOR = IJKW(4,IW)
    
   IF (NOM/=0 .OR. BOUNDARY_TYPE(IW)==SOLID_BOUNDARY .OR. BOUNDARY_TYPE(IW)==POROUS_BOUNDARY) THEN
      SELECT CASE(IOR)
         CASE( 1) 
            IF (PREDICTOR) DUUDT =       RFODT*(-UWS(IW)-U(II,JJ,KK))
            IF (CORRECTOR) DUUDT = 2._EB*RFODT*(-UW(IW)-0.5_EB*(U(II,JJ,KK)+US(II,JJ,KK)))
            FVX(II,JJ,KK) =   -RDXN(II)  *(HP(II+1,JJ,KK)-HP(II,JJ,KK)) - DUUDT
         CASE(-1) 
            IF (PREDICTOR) DUUDT =       RFODT*( UWS(IW)-U(II-1,JJ,KK))
            IF (CORRECTOR) DUUDT = 2._EB*RFODT*( UW(IW)-0.5_EB*(U(II-1,JJ,KK)+US(II-1,JJ,KK)))
            FVX(II-1,JJ,KK) = -RDXN(II-1)*(HP(II,JJ,KK)-HP(II-1,JJ,KK)) - DUUDT
         CASE( 2) 
            IF (PREDICTOR) DVVDT =       RFODT*(-UWS(IW)-V(II,JJ,KK))
            IF (CORRECTOR) DVVDT = 2._EB*RFODT*(-UW(IW)-0.5_EB*(V(II,JJ,KK)+VS(II,JJ,KK)))
            FVY(II,JJ,KK)   = -RDYN(JJ)  *(HP(II,JJ+1,KK)-HP(II,JJ,KK)) - DVVDT
         CASE(-2)
            IF (PREDICTOR) DVVDT =       RFODT*( UWS(IW)-V(II,JJ-1,KK))
            IF (CORRECTOR) DVVDT = 2._EB*RFODT*( UW(IW)-0.5_EB*(V(II,JJ-1,KK)+VS(II,JJ-1,KK)))
            FVY(II,JJ-1,KK) = -RDYN(JJ-1)*(HP(II,JJ,KK)-HP(II,JJ-1,KK)) - DVVDT
         CASE( 3) 
            IF (PREDICTOR) DWWDT =       RFODT*(-UWS(IW)-W(II,JJ,KK))
            IF (CORRECTOR) DWWDT = 2._EB*RFODT*(-UW(IW)-0.5_EB*(W(II,JJ,KK)+WS(II,JJ,KK)))
            FVZ(II,JJ,KK)   = -RDZN(KK)  *(HP(II,JJ,KK+1)-HP(II,JJ,KK)) - DWWDT
         CASE(-3) 
            IF (PREDICTOR) DWWDT =       RFODT*( UWS(IW)-W(II,JJ,KK-1))
            IF (CORRECTOR) DWWDT = 2._EB*RFODT*( UW(IW)-0.5_EB*(W(II,JJ,KK-1)+WS(II,JJ,KK-1)))
            FVZ(II,JJ,KK-1) = -RDZN(KK-1)*(HP(II,JJ,KK)-HP(II,JJ,KK-1)) - DWWDT
      END SELECT
   ENDIF

   IF (BOUNDARY_TYPE(IW)==MIRROR_BOUNDARY) THEN
      SELECT CASE(IOR)
         CASE( 1)
            FVX(II  ,JJ,KK) = 0._EB
         CASE(-1)
            FVX(II-1,JJ,KK) = 0._EB
         CASE( 2)
            FVY(II  ,JJ,KK) = 0._EB
         CASE(-2)
            FVY(II,JJ-1,KK) = 0._EB
         CASE( 3)
            FVZ(II  ,JJ,KK) = 0._EB
         CASE(-3)
            FVZ(II,JJ,KK-1) = 0._EB
      END SELECT
   ENDIF
 
ENDDO WALL_LOOP
!$OMP END DO
!$OMP END PARALLEL
 
END SUBROUTINE NO_FLUX
 
 

SUBROUTINE VELOCITY_PREDICTOR(NM,STOP_STATUS)

! Estimates the velocity components at the next time step

REAL(EB) :: TNOW,U2,V2,W2
INTEGER  :: STOP_STATUS,I,J,K
INTEGER, INTENT(IN) :: NM

IF (SOLID_PHASE_ONLY) RETURN
IF (FREEZE_VELOCITY) THEN
   CALL CHECK_STABILITY(NM,2)
   RETURN
ENDIF

TNOW=SECOND() 
CALL POINT_TO_MESH(NM)

!$OMP PARALLEL
!$OMP DO COLLAPSE(3) PRIVATE(K,J,I)
DO K=1,KBAR
   DO J=1,JBAR
      DO I=0,IBAR
         !!$ IF ((K == 1) .AND. (J == 1) .AND. (I == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_VELOCITY_PREDICTOR'
         US(I,J,K) = U(I,J,K) - DT*( FVX(I,J,K) + RDXN(I)*(H(I+1,J,K)-H(I,J,K)) )
      ENDDO
   ENDDO
ENDDO
!$OMP END DO NOWAIT

!$OMP DO COLLAPSE(3) PRIVATE(K,J,I)
DO K=1,KBAR
   DO J=0,JBAR
      DO I=1,IBAR
         VS(I,J,K) = V(I,J,K) - DT*( FVY(I,J,K) + RDYN(J)*(H(I,J+1,K)-H(I,J,K)) )
      ENDDO
   ENDDO
ENDDO
!$OMP END DO NOWAIT

!$OMP DO COLLAPSE(3) PRIVATE(K,J,I)
DO K=0,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         WS(I,J,K) = W(I,J,K) - DT*( FVZ(I,J,K) + RDZN(K)*(H(I,J,K+1)-H(I,J,K)) )
      ENDDO
   ENDDO
ENDDO
!$OMP END DO NOWAIT
!$OMP END PARALLEL

! Compute resolved kinetic energy per unit mass

DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         U2 = 0.25_EB*(US(I-1,J,K)+US(I,J,K))**2
         V2 = 0.25_EB*(VS(I,J-1,K)+VS(I,J,K))**2
         W2 = 0.25_EB*(WS(I,J,K-1)+WS(I,J,K))**2
         KRES(I,J,K) = 0.5_EB*(U2+V2+W2)
      ENDDO
   ENDDO
ENDDO

! No vertical velocity in Evacuation meshes

IF (EVACUATION_ONLY(NM)) WS = 0._EB

! Check the stability criteria, and if the time step is too small, send back a signal to kill the job
 
DT_PREV = DT
CALL CHECK_STABILITY(NM,2)
 
IF (DT<DT_INIT*LIMITING_DT_RATIO) STOP_STATUS = INSTABILITY_STOP
 
TUSED(4,NM)=TUSED(4,NM)+SECOND()-TNOW
END SUBROUTINE VELOCITY_PREDICTOR
 
 

SUBROUTINE VELOCITY_CORRECTOR(NM)

USE TURBULENCE, ONLY: TURBULENT_KINETIC_ENERGY

! Correct the velocity components

REAL(EB) :: TNOW,U2,V2,W2
INTEGER  :: I,J,K
INTEGER, INTENT(IN) :: NM
 
IF (SOLID_PHASE_ONLY) RETURN
IF (FREEZE_VELOCITY) RETURN

TNOW=SECOND() 
CALL POINT_TO_MESH(NM)

!$OMP PARALLEL
!$OMP DO COLLAPSE(3) PRIVATE(K,J,I)
DO K=1,KBAR
   DO J=1,JBAR
      DO I=0,IBAR
         !!$ IF ((K == 1) .AND. (J == 1) .AND. (I == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_VELOCITY_CORRECTOR'
         U(I,J,K) = 0.5_EB*( U(I,J,K) + US(I,J,K) - DT*(FVX(I,J,K) + RDXN(I)*(HS(I+1,J,K)-HS(I,J,K))) )
      ENDDO
   ENDDO
ENDDO
!$OMP END DO NOWAIT

!$OMP DO COLLAPSE(3) PRIVATE(K,J,I)
DO K=1,KBAR
   DO J=0,JBAR
      DO I=1,IBAR
         V(I,J,K) = 0.5_EB*( V(I,J,K) + VS(I,J,K) - DT*(FVY(I,J,K) + RDYN(J)*(HS(I,J+1,K)-HS(I,J,K))) )
      ENDDO
   ENDDO
ENDDO
!$OMP END DO NOWAIT

!$OMP DO COLLAPSE(3) PRIVATE(K,J,I)
DO K=0,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         W(I,J,K) = 0.5_EB*( W(I,J,K) + WS(I,J,K) - DT*(FVZ(I,J,K) + RDZN(K)*(HS(I,J,K+1)-HS(I,J,K))) )
      ENDDO
   ENDDO
ENDDO
!$OMP END DO NOWAIT
!$OMP END PARALLEL

! Compute resolved kinetic energy per unit mass

DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         U2 = 0.25_EB*(U(I-1,J,K)+U(I,J,K))**2
         V2 = 0.25_EB*(V(I,J-1,K)+V(I,J,K))**2
         W2 = 0.25_EB*(W(I,J,K-1)+W(I,J,K))**2
         KRES(I,J,K) = 0.5_EB*(U2+V2+W2)
      ENDDO
   ENDDO
ENDDO

! No vertical velocity in Evacuation meshes

IF (EVACUATION_ONLY(NM)) W = 0._EB

IF (CHECK_KINETIC_ENERGY .AND. .NOT.EVACUATION_ONLY(NM)) CALL TURBULENT_KINETIC_ENERGY(NM)

TUSED(4,NM)=TUSED(4,NM)+SECOND()-TNOW
END SUBROUTINE VELOCITY_CORRECTOR
 

 
SUBROUTINE VELOCITY_BC(T,NM)

! Assert tangential velocity boundary conditions

USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
USE TURBULENCE, ONLY: WERNER_WENGLE_WALL_MODEL
REAL(EB), INTENT(IN) :: T
REAL(EB) :: MUA,TSI,WGT,TNOW,RAMP_T,OMW,MU_WALL,RHO_WALL,SLIP_COEF,VEL_T, &
            UUP(2),UUM(2),DXX(2),MU_DUIDXJ(-2:2),DUIDXJ(-2:2),MU_DUIDXJ_0(2),DUIDXJ_0(2),PROFILE_FACTOR,VEL_GAS,VEL_GHOST, &
            MU_DUIDXJ_USE(2),DUIDXJ_USE(2),DUMMY
INTEGER  :: I,J,K,NOM(2),IIO(2),JJO(2),KKO(2),IE,II,JJ,KK,IEC,IOR,IWM,IWP,ICMM,ICMP,ICPM,ICPP,IC,ICD,ICDO,IVL,I_SGN,IS, &
            VELOCITY_BC_INDEX,IIGM,JJGM,KKGM,IIGP,JJGP,KKGP,IBCM,IBCP,ITMP,ICD_SGN,ICDO_SGN
LOGICAL :: ALTERED_GRADIENT(-2:2),PROCESS_EDGE
INTEGER, INTENT(IN) :: NM
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL(),U_Y=>NULL(),U_Z=>NULL(), &
                                       V_X=>NULL(),V_Z=>NULL(),W_X=>NULL(),W_Y=>NULL(),RHOP=>NULL(),VEL_OTHER=>NULL()
TYPE (SURFACE_TYPE), POINTER :: SF=>NULL()
TYPE (OMESH_TYPE), POINTER :: OM=>NULL()

IF (SOLID_PHASE_ONLY) RETURN

TNOW = SECOND()

! Assign local names to variables

CALL POINT_TO_MESH(NM)

! Point to the appropriate velocity field

IF (PREDICTOR) THEN
   UU => US
   VV => VS
   WW => WS
   RHOP => RHOS
ELSE
   UU => U
   VV => V
   WW => W
   RHOP => RHO
ENDIF


! Set the boundary velocity place holder to some large negative number

IF (CORRECTOR) THEN
   
   U_Y => WORK1
   U_Z => WORK2
   V_X => WORK3
   V_Z => WORK4
   W_X => WORK5
   W_Y => WORK6
   !$OMP PARALLEL WORKSHARE
   U_Y = -1.E6_EB
   U_Z = -1.E6_EB
   V_X = -1.E6_EB
   V_Z = -1.E6_EB
   W_X = -1.E6_EB
   W_Y = -1.E6_EB
   UVW_GHOST = -1.E6_EB
   !$OMP END PARALLEL WORKSHARE
ENDIF

!$OMP PARALLEL

! Set OME_E and TAU_E to very negative number

!$OMP WORKSHARE
TAU_E = -1.E6_EB
OME_E = -1.E6_EB
!$OMP END WORKSHARE

! Loop over all cell edges and determine the appropriate velocity BCs

!$OMP DO PRIVATE(IE,II,JJ,KK,IEC,ICMM,ICPM,ICMP,ICPP,NOM,IIO,JJO,KKO,UUP,UUM,DXX,MUA,I_SGN,IS,IOR,ICD,IVL,ICD_SGN,IBCM,IBCP,ITMP) &
!$OMP PRIVATE(VEL_GAS,VEL_GHOST,IWP,IWM,SF,VELOCITY_BC_INDEX,TSI,PROFILE_FACTOR,RAMP_T,VEL_T,IIGM,JJGM,KKGM,IIGP,JJGP,KKGP) &
!$OMP PRIVATE(RHO_WALL,MU_WALL,OM,VEL_OTHER,WGT,OMW,ICDO,MU_DUIDXJ,DUIDXJ,DUIDXJ_0,MU_DUIDXJ_0,MU_DUIDXJ_USE,DUIDXJ_USE) &
!$OMP PRIVATE(PROCESS_EDGE,ALTERED_GRADIENT,SLIP_COEF,ICDO_SGN)
EDGE_LOOP: DO IE=1,N_EDGES

   IF (EDGE_TYPE(IE,1)==NULL_EDGE .AND. EDGE_TYPE(IE,2)==NULL_EDGE) CYCLE EDGE_LOOP

   ! Throw out edges that are completely surrounded by blockages or the exterior of the domain

   PROCESS_EDGE = .FALSE.
   DO IS=5,8
      IF (.NOT.EXTERIOR(IJKE(IS,IE)) .AND. .NOT.SOLID(IJKE(IS,IE))) THEN
         PROCESS_EDGE = .TRUE.
         EXIT
      ENDIF
   ENDDO
   IF (.NOT.PROCESS_EDGE) CYCLE EDGE_LOOP

   ! If the edge is to be "smoothed," set tau and omega to zero and cycle

   IF (EDGE_TYPE(IE,1)==SMOOTH_EDGE) THEN
      OME_E(IE,:) = 0._EB
      TAU_E(IE,:) = 0._EB
      CYCLE EDGE_LOOP
   ENDIF

   ! Unpack indices for the edge

   II     = IJKE( 1,IE)
   JJ     = IJKE( 2,IE)
   KK     = IJKE( 3,IE)
   IEC    = IJKE( 4,IE)
   ICMM   = IJKE( 5,IE)
   ICPM   = IJKE( 6,IE)
   ICMP   = IJKE( 7,IE)
   ICPP   = IJKE( 8,IE)
   NOM(1) = IJKE( 9,IE)
   IIO(1) = IJKE(10,IE)
   JJO(1) = IJKE(11,IE)
   KKO(1) = IJKE(12,IE)
   NOM(2) = IJKE(13,IE)
   IIO(2) = IJKE(14,IE)
   JJO(2) = IJKE(15,IE)
   KKO(2) = IJKE(16,IE)

   ! Get the velocity components at the appropriate cell faces     
 
   COMPONENT: SELECT CASE(IEC)
      CASE(1) COMPONENT    
         UUP(1)  = VV(II,JJ,KK+1)
         UUM(1)  = VV(II,JJ,KK)
         UUP(2)  = WW(II,JJ+1,KK)
         UUM(2)  = WW(II,JJ,KK)
         DXX(1)  = DY(JJ)
         DXX(2)  = DZ(KK)
         MUA      = 0.25_EB*(MU(II,JJ,KK) + MU(II,JJ+1,KK) + MU(II,JJ+1,KK+1) + MU(II,JJ,KK+1) )
      CASE(2) COMPONENT  
         UUP(1)  = WW(II+1,JJ,KK)
         UUM(1)  = WW(II,JJ,KK)
         UUP(2)  = UU(II,JJ,KK+1)
         UUM(2)  = UU(II,JJ,KK)
         DXX(1)  = DZ(KK)
         DXX(2)  = DX(II)
         MUA      = 0.25_EB*(MU(II,JJ,KK) + MU(II+1,JJ,KK) + MU(II+1,JJ,KK+1) + MU(II,JJ,KK+1) )
      CASE(3) COMPONENT 
         UUP(1)  = UU(II,JJ+1,KK)
         UUM(1)  = UU(II,JJ,KK)
         UUP(2)  = VV(II+1,JJ,KK)
         UUM(2)  = VV(II,JJ,KK)
         DXX(1)  = DX(II)
         DXX(2)  = DY(JJ)
         MUA      = 0.25_EB*(MU(II,JJ,KK) + MU(II+1,JJ,KK) + MU(II+1,JJ+1,KK) + MU(II,JJ+1,KK) )
   END SELECT COMPONENT

   ! Indicate that the velocity gradients in the two orthogonal directions have not been changed yet

   ALTERED_GRADIENT = .FALSE.

   ! Loop over all possible orientations of edge and reassign velocity gradients if appropriate

   SIGN_LOOP: DO I_SGN=-1,1,2
      ORIENTATION_LOOP: DO IS=1,3
         IF (IS==IEC) CYCLE ORIENTATION_LOOP

         IOR = I_SGN*IS

         ! Determine Index_Coordinate_Direction
         ! IEC=1, ICD=1 refers to DWDY; ICD=2 refers to DVDZ
         ! IEC=2, ICD=1 refers to DUDZ; ICD=2 refers to DWDX
         ! IEC=3, ICD=1 refers to DVDX; ICD=2 refers to DUDY

         IF (IS>IEC) ICD = IS-IEC
         IF (IS<IEC) ICD = IS-IEC+3
         IF (ICD==1) THEN ! Used to pick the appropriate velocity component
            IVL=2
         ELSE !ICD==2
            IVL=1
         ENDIF
         ICD_SGN = I_SGN * ICD   
         ! IWM and IWP are the wall cell indices of the boundary on either side of the edge.
         IF (IOR<0) THEN
            VEL_GAS   = UUM(IVL)
            VEL_GHOST = UUP(IVL)
            IWM  = WALL_INDEX(ICMM,IS)
            IIGM = I_CELL(ICMM)
            JJGM = J_CELL(ICMM)
            KKGM = K_CELL(ICMM)
            IF (ICD==1) THEN
               IWP  = WALL_INDEX(ICMP,IS)
               IIGP = I_CELL(ICMP)
               JJGP = J_CELL(ICMP)
               KKGP = K_CELL(ICMP)
            ELSE ! ICD==2
               IWP  = WALL_INDEX(ICPM,IS)
               IIGP = I_CELL(ICPM)
               JJGP = J_CELL(ICPM)
               KKGP = K_CELL(ICPM)
            ENDIF
         ELSE
            VEL_GAS   = UUP(IVL)
            VEL_GHOST = UUM(IVL)
            IF (ICD==1) THEN
               IWM  = WALL_INDEX(ICPM,-IOR)
               IIGM = I_CELL(ICPM)
               JJGM = J_CELL(ICPM)
               KKGM = K_CELL(ICPM)
            ELSE ! ICD==2
               IWM  = WALL_INDEX(ICMP,-IOR)
               IIGM = I_CELL(ICMP)
               JJGM = J_CELL(ICMP)
               KKGM = K_CELL(ICMP)
            ENDIF
            IWP  = WALL_INDEX(ICPP,-IOR)
            IIGP = I_CELL(ICPP)
            JJGP = J_CELL(ICPP)
            KKGP = K_CELL(ICPP)
         ENDIF
         ! Throw out edge orientations that need not be processed
   
         IF (BOUNDARY_TYPE(IWM)==NULL_BOUNDARY .AND. BOUNDARY_TYPE(IWP)==NULL_BOUNDARY) CYCLE ORIENTATION_LOOP

         ! Decide whether or not to process edge using data interpolated from another mesh
   
         INTERPOLATION_IF: IF (NOM(ICD)==0 .OR. &
                              (BOUNDARY_TYPE(IWM)/=INTERPOLATED_BOUNDARY .AND. BOUNDARY_TYPE(IWP)/=INTERPOLATED_BOUNDARY)) THEN

            ! Determine appropriate velocity BC by assessing each adjacent wall cell. If the BCs are different on each
            ! side of the edge, choose the one with the specified velocity, if there is one. If not, choose the max value of
            ! boundary condition index, simply for consistency.

            IBCM = 0
            IBCP = 0
            IF (IWM>0) IBCM = IJKW(5,IWM)
            IF (IWP>0) IBCP = IJKW(5,IWP)
            IF (SURFACE(IBCM)%SPECIFIED_NORMAL_VELOCITY) THEN
               SF=>SURFACE(IBCM)
            ELSEIF (SURFACE(IBCP)%SPECIFIED_NORMAL_VELOCITY) THEN
               SF=>SURFACE(IBCP)
            ELSE
               SF => SURFACE(MAX(IBCM,IBCP))
            ENDIF
            VELOCITY_BC_INDEX = SF%VELOCITY_BC_INDEX

            ! Compute the viscosity in the two adjacent gas cells

            MUA = 0.5_EB*(MU(IIGM,JJGM,KKGM) + MU(IIGP,JJGP,KKGP))

            ! Determine if there is a tangential velocity component

            IF (.NOT.SF%SPECIFIED_TANGENTIAL_VELOCITY) THEN
               VEL_T = 0._EB
            ELSE
               IF (SF%T_IGN==T_BEGIN .AND. SF%RAMP_INDEX(TIME_VELO)>=1) THEN
                  TSI = T
               ELSE
                  TSI=T-SF%T_IGN
               ENDIF
               PROFILE_FACTOR = 1._EB
               IF (SF%PROFILE==ATMOSPHERIC) PROFILE_FACTOR = (MAX(0._EB,ZC(KK)-GROUND_LEVEL)/SF%Z0)**SF%PLE
               RAMP_T = EVALUATE_RAMP(TSI,SF%TAU(TIME_VELO),SF%RAMP_INDEX(TIME_VELO))
               IF (IEC==1 .OR. (IEC==2 .AND. ICD==2)) VEL_T = SF%VEL_T(2)
               IF (IEC==3 .OR. (IEC==2 .AND. ICD==1)) VEL_T = SF%VEL_T(1)
               VEL_T = PROFILE_FACTOR*RAMP_T*VEL_T
            ENDIF
 
            ! Choose the appropriate boundary condition to apply

            BOUNDARY_CONDITION: SELECT CASE(VELOCITY_BC_INDEX)

               CASE (FREE_SLIP_BC) BOUNDARY_CONDITION

                  VEL_GHOST = VEL_GAS
                  DUIDXJ(ICD_SGN) = I_SGN*(VEL_GAS-VEL_GHOST)/DXX(ICD)
                  MU_DUIDXJ(ICD_SGN) = MUA*DUIDXJ(ICD_SGN)
                  ALTERED_GRADIENT(ICD_SGN) = .TRUE.

               CASE (NO_SLIP_BC) BOUNDARY_CONDITION

                  VEL_GHOST = 2._EB*VEL_T - VEL_GAS
                  DUIDXJ(ICD_SGN) = I_SGN*(VEL_GAS-VEL_GHOST)/DXX(ICD)
                  MU_DUIDXJ(ICD_SGN) = MUA*DUIDXJ(ICD_SGN)
                  ALTERED_GRADIENT(ICD_SGN) = .TRUE.

               CASE (WALL_MODEL) BOUNDARY_CONDITION

                  IF ( SOLID(CELL_INDEX(IIGM,JJGM,KKGM)) .OR. SOLID(CELL_INDEX(IIGP,JJGP,KKGP)) ) THEN
                     MU_WALL = MUA
                     SLIP_COEF=-1._EB
                  ELSE
                     ITMP = MIN(5000,NINT(0.5_EB*(TMP(IIGM,JJGM,KKGM)+TMP(IIGP,JJGP,KKGP))))
                     MU_WALL = Y2MU_C(ITMP)*SPECIES(0)%MW
                     RHO_WALL = 0.5_EB*( RHOP(IIGM,JJGM,KKGM) + RHOP(IIGP,JJGP,KKGP) )
                     CALL WERNER_WENGLE_WALL_MODEL(SLIP_COEF,DUMMY,VEL_GAS-VEL_T,MU_WALL/RHO_WALL,DXX(ICD),SF%ROUGHNESS)
                  ENDIF
                  VEL_GHOST = 2._EB*VEL_T - VEL_GAS
                  DUIDXJ(ICD_SGN) = I_SGN*(VEL_GAS-VEL_GHOST)/DXX(ICD)
                  MU_DUIDXJ(ICD_SGN) = MU_WALL*(VEL_GAS-VEL_T)*I_SGN*(1._EB-SLIP_COEF)/DXX(ICD)
                  ALTERED_GRADIENT(ICD_SGN) = .TRUE.
                  IF (BOUNDARY_TYPE(IWM)==SOLID_BOUNDARY .NEQV. BOUNDARY_TYPE(IWP)==SOLID_BOUNDARY) THEN
                     DUIDXJ(ICD_SGN) = 0.5_EB*DUIDXJ(ICD_SGN)
                     MU_DUIDXJ(ICD_SGN) = 0.5_EB*MU_DUIDXJ(ICD_SGN)
                  ENDIF

            END SELECT BOUNDARY_CONDITION

         ELSE INTERPOLATION_IF  ! Use data from another mesh
 
            OM => OMESH(ABS(NOM(ICD)))
   
            IF (PREDICTOR) THEN
               SELECT CASE(IEC)
                  CASE(1)
                     IF (ICD==1) THEN
                        VEL_OTHER => OM%WS
                     ELSE
                        VEL_OTHER => OM%VS
                     ENDIF !ICD==2
                  CASE(2)
                     IF (ICD==1) THEN
                        VEL_OTHER => OM%US
                     ELSE !ICD==2
                        VEL_OTHER => OM%WS
                     ENDIF
                  CASE(3) !ICD==2
                     IF (ICD==1) THEN
                        VEL_OTHER => OM%VS
                     ELSE
                        VEL_OTHER => OM%US
                     ENDIF
               END SELECT
            ELSE
               SELECT CASE(IEC)
                  CASE(1) !ICD==2
                     IF (ICD==1) THEN
                        VEL_OTHER => OM%W
                     ELSE
                        VEL_OTHER => OM%V
                     ENDIF
                  CASE(2) !ICD==2
                     IF (ICD==1) THEN
                        VEL_OTHER => OM%U
                     ELSE !ICD==2
                        VEL_OTHER => OM%W
                     ENDIF
                  CASE(3)
                     IF (ICD==1) THEN
                        VEL_OTHER => OM%V
                     ELSE !ICD==2
                        VEL_OTHER => OM%U
                     ENDIF
               END SELECT
            ENDIF
   
            WGT = EDGE_INTERPOLATION_FACTOR(IE,ICD)
            OMW = 1._EB-WGT

            SELECT CASE(IEC)
               CASE(1)
                  IF (ICD==1) THEN
                     VEL_GHOST = WGT*VEL_OTHER(IIO(ICD),JJO(ICD),KKO(ICD)) + OMW*VEL_OTHER(IIO(ICD),JJO(ICD),KKO(ICD)-1)
                  ELSE !ICD=2
                     VEL_GHOST = WGT*VEL_OTHER(IIO(ICD),JJO(ICD),KKO(ICD)) + OMW*VEL_OTHER(IIO(ICD),JJO(ICD)-1,KKO(ICD))
                  ENDIF
                  MUA = 0.25_EB*(MU(II,JJ,KK) + MU(II,JJ+1,KK) + MU(II,JJ+1,KK+1) + MU(II,JJ,KK+1) )
               CASE(2)
                  IF (ICD==1) THEN
                     VEL_GHOST = WGT*VEL_OTHER(IIO(ICD),JJO(ICD),KKO(ICD)) + OMW*VEL_OTHER(IIO(ICD)-1,JJO(ICD),KKO(ICD))
                  ELSE !ICD==2
                     VEL_GHOST = WGT*VEL_OTHER(IIO(ICD),JJO(ICD),KKO(ICD)) + OMW*VEL_OTHER(IIO(ICD),JJO(ICD),KKO(ICD)-1)
                  ENDIF
                  MUA = 0.25_EB*(MU(II,JJ,KK) + MU(II+1,JJ,KK) + MU(II+1,JJ,KK+1) + MU(II,JJ,KK+1) )
               CASE(3)
                  IF (ICD==1) THEN
                     VEL_GHOST = WGT*VEL_OTHER(IIO(ICD),JJO(ICD),KKO(ICD)) + OMW*VEL_OTHER(IIO(ICD),JJO(ICD)-1,KKO(ICD))
                  ELSE !ICD==2
                     VEL_GHOST = WGT*VEL_OTHER(IIO(ICD),JJO(ICD),KKO(ICD)) + OMW*VEL_OTHER(IIO(ICD)-1,JJO(ICD),KKO(ICD))
                  ENDIF
                  MUA = 0.25_EB*(MU(II,JJ,KK) + MU(II+1,JJ,KK) + MU(II+1,JJ+1,KK) + MU(II,JJ+1,KK) )
            END SELECT
            DUIDXJ(ICD_SGN) = I_SGN*(VEL_GAS-VEL_GHOST)/DXX(ICD)
            MU_DUIDXJ(ICD_SGN) = MUA*I_SGN*(VEL_GAS-VEL_GHOST)/DXX(ICD)
            ALTERED_GRADIENT(ICD_SGN) = .TRUE.
   
         ENDIF INTERPOLATION_IF

         ! Set ghost cell values at edge of computational domain
   
         SELECT CASE(IEC)
            CASE(1)
               IF (JJ==0    .AND. IOR== 2) WW(II,JJ,KK)   = VEL_GHOST
               IF (JJ==JBAR .AND. IOR==-2) WW(II,JJ+1,KK) = VEL_GHOST
               IF (KK==0    .AND. IOR== 3) VV(II,JJ,KK)   = VEL_GHOST
               IF (KK==KBAR .AND. IOR==-3) VV(II,JJ,KK+1) = VEL_GHOST
               IF (CORRECTOR .AND. JJ>0 .AND. JJ<JBAR .AND. KK>0 .AND. KK<KBAR) THEN
                 IF (ICD==1) THEN
                    W_Y(II,JJ,KK) = 0.5_EB*(VEL_GHOST+VEL_GAS)
                 ELSE !ICD==2
                    V_Z(II,JJ,KK) = 0.5_EB*(VEL_GHOST+VEL_GAS)
                 ENDIF
               ENDIF
            CASE(2)
               IF (II==0    .AND. IOR== 1) WW(II,JJ,KK)   = VEL_GHOST
               IF (II==IBAR .AND. IOR==-1) WW(II+1,JJ,KK) = VEL_GHOST
               IF (KK==0    .AND. IOR== 3) UU(II,JJ,KK)   = VEL_GHOST
               IF (KK==KBAR .AND. IOR==-3) UU(II,JJ,KK+1) = VEL_GHOST
               IF (CORRECTOR .AND. II>0 .AND. II<IBAR .AND. KK>0 .AND. KK<KBAR) THEN
                 IF (ICD==1) THEN
                    U_Z(II,JJ,KK) = 0.5_EB*(VEL_GHOST+VEL_GAS)
                 ELSE !ICD==2
                    W_X(II,JJ,KK) = 0.5_EB*(VEL_GHOST+VEL_GAS)
                 ENDIF
               ENDIF
            CASE(3)
               IF (II==0    .AND. IOR== 1) VV(II,JJ,KK)   = VEL_GHOST
               IF (II==IBAR .AND. IOR==-1) VV(II+1,JJ,KK) = VEL_GHOST
               IF (JJ==0    .AND. IOR== 2) UU(II,JJ,KK)   = VEL_GHOST
               IF (JJ==JBAR .AND. IOR==-2) UU(II,JJ+1,KK) = VEL_GHOST
               IF (CORRECTOR .AND. II>0 .AND. II<IBAR .AND. JJ>0 .AND. JJ<JBAR) THEN
                 IF (ICD==1) THEN
                    V_X(II,JJ,KK) = 0.5_EB*(VEL_GHOST+VEL_GAS)
                 ELSE !ICD==2
                    U_Y(II,JJ,KK) = 0.5_EB*(VEL_GHOST+VEL_GAS)
                 ENDIF
               ENDIF
         END SELECT
      ENDDO ORIENTATION_LOOP
   
   ENDDO SIGN_LOOP
   ! Save vorticity and viscous stress for use in momentum equation
   DUIDXJ_0(1)    = (UUP(2)-UUM(2))/DXX(1)
   DUIDXJ_0(2)    = (UUP(1)-UUM(1))/DXX(2)
   MU_DUIDXJ_0(1) = MUA*DUIDXJ_0(1)
   MU_DUIDXJ_0(2) = MUA*DUIDXJ_0(2)

   SIGN_LOOP_2: DO I_SGN=-1,1,2
      ORIENTATION_LOOP_2: DO ICD=1,2
         IF (ICD==1) THEN
            ICDO=2
         ELSE !ICD==2)
            ICDO=1
         ENDIF
         ICD_SGN = I_SGN*ICD
         IF (ALTERED_GRADIENT(ICD_SGN)) THEN
               DUIDXJ_USE(ICD) =    DUIDXJ(ICD_SGN)
            MU_DUIDXJ_USE(ICD) = MU_DUIDXJ(ICD_SGN)
         ELSEIF (ALTERED_GRADIENT(-ICD_SGN)) THEN
               DUIDXJ_USE(ICD) =    DUIDXJ(-ICD_SGN)
            MU_DUIDXJ_USE(ICD) = MU_DUIDXJ(-ICD_SGN)
         ELSE
            CYCLE
         ENDIF
         ICDO_SGN = I_SGN*ICDO
         IF (ALTERED_GRADIENT(ICDO_SGN) .AND. ALTERED_GRADIENT(-ICDO_SGN)) THEN
               DUIDXJ_USE(ICDO) =    0.5_EB*(DUIDXJ(ICDO_SGN)+   DUIDXJ(-ICDO_SGN))
            MU_DUIDXJ_USE(ICDO) = 0.5_EB*(MU_DUIDXJ(ICDO_SGN)+MU_DUIDXJ(-ICDO_SGN))
         ELSEIF (ALTERED_GRADIENT(ICDO_SGN)) THEN
               DUIDXJ_USE(ICDO) =    DUIDXJ(ICDO_SGN)
            MU_DUIDXJ_USE(ICDO) = MU_DUIDXJ(ICDO_SGN)
         ELSEIF (ALTERED_GRADIENT(-ICDO_SGN)) THEN
               DUIDXJ_USE(ICDO) =    DUIDXJ(-ICDO_SGN)
            MU_DUIDXJ_USE(ICDO) = MU_DUIDXJ(-ICDO_SGN)
         ELSE
               DUIDXJ_USE(ICDO) =    DUIDXJ_0(ICDO)
            MU_DUIDXJ_USE(ICDO) = MU_DUIDXJ_0(ICDO)
         ENDIF
         OME_E(IE,ICD_SGN) =    DUIDXJ_USE(1) -    DUIDXJ_USE(2)
         TAU_E(IE,ICD_SGN) = MU_DUIDXJ_USE(1) + MU_DUIDXJ_USE(2)    
      ENDDO ORIENTATION_LOOP_2
   ENDDO SIGN_LOOP_2

ENDDO EDGE_LOOP
!$OMP END DO

! Store cell node averages of the velocity components in UVW_GHOST for use in Smokeview only

IF (CORRECTOR) THEN
   !$OMP DO COLLAPSE(3) PRIVATE(K,J,I,IC)
   DO K=0,KBAR
      DO J=0,JBAR
         DO I=0,IBAR
            !!$ IF ((K == 1) .AND. (J == 1) .AND. (I == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_VELOCITY_BC_02'
            IC = CELL_INDEX(I,J,K) 
            IF (IC==0) CYCLE
            IF (U_Y(I,J,K)  >-1.E5_EB) UVW_GHOST(IC,1) = U_Y(I,J,K) 
            IF (U_Z(I,J,K)  >-1.E5_EB) UVW_GHOST(IC,1) = U_Z(I,J,K) 
            IF (V_X(I,J,K)  >-1.E5_EB) UVW_GHOST(IC,2) = V_X(I,J,K) 
            IF (V_Z(I,J,K)  >-1.E5_EB) UVW_GHOST(IC,2) = V_Z(I,J,K) 
            IF (W_X(I,J,K)  >-1.E5_EB) UVW_GHOST(IC,3) = W_X(I,J,K) 
            IF (W_Y(I,J,K)  >-1.E5_EB) UVW_GHOST(IC,3) = W_Y(I,J,K)
         ENDDO
      ENDDO
   ENDDO
   !$OMP END DO NOWAIT
ENDIF
!$OMP END PARALLEL

TUSED(4,NM)=TUSED(4,NM)+SECOND()-TNOW
END SUBROUTINE VELOCITY_BC 
 
 
 
SUBROUTINE MATCH_VELOCITY(NM)

! Force normal component of velocity to match at interpolated boundaries

INTEGER  :: NOM,II,JJ,KK,IOR,IW,IIO,JJO,KKO,IIG,JJG,KKG
INTEGER, INTENT(IN) :: NM
REAL(EB) :: UU_AVG,VV_AVG,WW_AVG,TNOW,DA_OTHER,UU_OTHER,VV_OTHER,WW_OTHER
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL(),OM_UU=>NULL(),OM_VV=>NULL(),OM_WW=>NULL()
TYPE (OMESH_TYPE), POINTER :: OM=>NULL()
TYPE (MESH_TYPE), POINTER :: M2=>NULL()

IF (SOLID_PHASE_ONLY) RETURN
IF (NMESHES==1 .AND. PERIODIC_TEST==0) RETURN
IF (EVACUATION_ONLY(NM)) RETURN

TNOW = SECOND()

! Assign local variable names

CALL POINT_TO_MESH(NM)

! Point to the appropriate velocity field

IF (PREDICTOR) THEN
   UU => US
   VV => VS
   WW => WS
   D_CORR = 0._EB
ELSE
   UU => U
   VV => V
   WW => W
   DS_CORR = 0._EB
ENDIF

! Loop over all cell edges and determine the appropriate velocity BCs

!$OMP PARALLEL DO PRIVATE(IW,II,JJ,KK,IOR,IIG,JJG,KKG,NOM,OM,M2,DA_OTHER,OM_UU,OM_VV,OM_WW,KKO,JJO,IIO) &
!$OMP PRIVATE(UU_OTHER,VV_OTHER,WW_OTHER,UU_AVG,VV_AVG,WW_AVG)
EXTERNAL_WALL_LOOP: DO IW=1,NEWC

   !!$ IF ((IW == 1) .AND. DEBUG_OPENMP) WRITE(*,*) 'OpenMP_VELO_24'
   
   IF (IJKW(9,IW)==0) CYCLE EXTERNAL_WALL_LOOP

   II  = IJKW( 1,IW)
   JJ  = IJKW( 2,IW)
   KK  = IJKW( 3,IW)
   IOR = IJKW( 4,IW)
   IIG = IJKW(6,IW)
   JJG = IJKW(7,IW)
   KKG = IJKW(8,IW)
   NOM = IJKW( 9,IW)
   OM => OMESH(NOM)
   M2 => MESHES(NOM)
   
   ! Determine the area of the interpolated cell face
   
   DA_OTHER = 0._EB

   SELECT CASE(ABS(IOR))
      CASE(1)
         IF (PREDICTOR) OM_UU => OM%US
         IF (CORRECTOR) OM_UU => OM%U 
         DO KKO=IJKW(12,IW),IJKW(15,IW)
            DO JJO=IJKW(11,IW),IJKW(14,IW)
               DO IIO=IJKW(10,IW),IJKW(13,IW)
                  DA_OTHER = DA_OTHER + M2%DY(JJO)*M2%DZ(KKO)
               ENDDO
            ENDDO
         ENDDO
      CASE(2)
         IF (PREDICTOR) OM_VV => OM%VS
         IF (CORRECTOR) OM_VV => OM%V
         DO KKO=IJKW(12,IW),IJKW(15,IW)
            DO JJO=IJKW(11,IW),IJKW(14,IW)
               DO IIO=IJKW(10,IW),IJKW(13,IW)
                  DA_OTHER = DA_OTHER + M2%DX(IIO)*M2%DZ(KKO)
               ENDDO
            ENDDO
         ENDDO
      CASE(3)
         IF (PREDICTOR) OM_WW => OM%WS
         IF (CORRECTOR) OM_WW => OM%W
         DO KKO=IJKW(12,IW),IJKW(15,IW)
            DO JJO=IJKW(11,IW),IJKW(14,IW)
               DO IIO=IJKW(10,IW),IJKW(13,IW)
                  DA_OTHER = DA_OTHER + M2%DX(IIO)*M2%DY(JJO)
               ENDDO
            ENDDO
         ENDDO
   END SELECT
   
   ! Determine the normal component of velocity from the other mesh and use it for average

   SELECT CASE(IOR)
   
      CASE( 1)
      
         UU_OTHER = 0._EB
         DO KKO=IJKW(12,IW),IJKW(15,IW)
            DO JJO=IJKW(11,IW),IJKW(14,IW)
               DO IIO=IJKW(10,IW),IJKW(13,IW)
                  UU_OTHER = UU_OTHER + OM_UU(IIO,JJO,KKO)*M2%DY(JJO)*M2%DZ(KKO)/DA_OTHER
               ENDDO
            ENDDO
         ENDDO
         UU_AVG = 0.5_EB*(UU(0,JJ,KK) + UU_OTHER)
         IF (PREDICTOR) D_CORR(IW) = DS_CORR(IW) + 0.5*(UU_AVG-UU(0,JJ,KK))*RDX(1)
         IF (CORRECTOR) DS_CORR(IW) = (UU_AVG-UU(0,JJ,KK))*RDX(1)
         UVW_SAVE(IW) = UU(0,JJ,KK)
         UU(0,JJ,KK)  = UU_AVG

      CASE(-1)
         
         UU_OTHER = 0._EB
         DO KKO=IJKW(12,IW),IJKW(15,IW)
            DO JJO=IJKW(11,IW),IJKW(14,IW)
               DO IIO=IJKW(10,IW),IJKW(13,IW)
                  UU_OTHER = UU_OTHER + OM_UU(IIO-1,JJO,KKO)*M2%DY(JJO)*M2%DZ(KKO)/DA_OTHER
               ENDDO
            ENDDO
         ENDDO
         UU_AVG = 0.5_EB*(UU(IBAR,JJ,KK) + UU_OTHER)
         IF (PREDICTOR) D_CORR(IW) = DS_CORR(IW) - 0.5*(UU_AVG-UU(IBAR,JJ,KK))*RDX(IBAR)
         IF (CORRECTOR) DS_CORR(IW) = -(UU_AVG-UU(IBAR,JJ,KK))*RDX(IBAR)
         UVW_SAVE(IW) = UU(IBAR,JJ,KK)
         UU(IBAR,JJ,KK) = UU_AVG

      CASE( 2)
      
         VV_OTHER = 0._EB
         DO KKO=IJKW(12,IW),IJKW(15,IW)
            DO JJO=IJKW(11,IW),IJKW(14,IW)
               DO IIO=IJKW(10,IW),IJKW(13,IW)
                  VV_OTHER = VV_OTHER + OM_VV(IIO,JJO,KKO)*M2%DX(IIO)*M2%DZ(KKO)/DA_OTHER
               ENDDO
            ENDDO
         ENDDO
         VV_AVG = 0.5_EB*(VV(II,0,KK) + VV_OTHER)
         IF (PREDICTOR) D_CORR(IW) = DS_CORR(IW) + 0.5*(VV_AVG-VV(II,0,KK))*RDY(1)
         IF (CORRECTOR) DS_CORR(IW) = (VV_AVG-VV(II,0,KK))*RDY(1)
         UVW_SAVE(IW) = VV(II,0,KK)
         VV(II,0,KK)  = VV_AVG

      CASE(-2)
      
         VV_OTHER = 0._EB
         DO KKO=IJKW(12,IW),IJKW(15,IW)
            DO JJO=IJKW(11,IW),IJKW(14,IW)
               DO IIO=IJKW(10,IW),IJKW(13,IW)
                  VV_OTHER = VV_OTHER + OM_VV(IIO,JJO-1,KKO)*M2%DX(IIO)*M2%DZ(KKO)/DA_OTHER
               ENDDO
            ENDDO
         ENDDO
         VV_AVG = 0.5_EB*(VV(II,JBAR,KK) + VV_OTHER)
         IF (PREDICTOR) D_CORR(IW) = DS_CORR(IW) - 0.5*(VV_AVG-VV(II,JBAR,KK))*RDY(JBAR)
         IF (CORRECTOR) DS_CORR(IW) = -(VV_AVG-VV(II,JBAR,KK))*RDY(JBAR)
         UVW_SAVE(IW)   = VV(II,JBAR,KK)
         VV(II,JBAR,KK) = VV_AVG

      CASE( 3)
      
         WW_OTHER = 0._EB
         DO KKO=IJKW(12,IW),IJKW(15,IW)
            DO JJO=IJKW(11,IW),IJKW(14,IW)
               DO IIO=IJKW(10,IW),IJKW(13,IW)
                  WW_OTHER = WW_OTHER + OM_WW(IIO,JJO,KKO)*M2%DX(IIO)*M2%DY(JJO)/DA_OTHER
               ENDDO
            ENDDO
         ENDDO
         WW_AVG = 0.5_EB*(WW(II,JJ,0) + WW_OTHER)
         IF (PREDICTOR) D_CORR(IW) = DS_CORR(IW) + 0.5*(WW_AVG-WW(II,JJ,0))*RDZ(1)
         IF (CORRECTOR) DS_CORR(IW) = (WW_AVG-WW(II,JJ,0))*RDZ(1)
         UVW_SAVE(IW) = WW(II,JJ,0)
         WW(II,JJ,0)  = WW_AVG

      CASE(-3)
      
         WW_OTHER = 0._EB
         DO KKO=IJKW(12,IW),IJKW(15,IW)
            DO JJO=IJKW(11,IW),IJKW(14,IW)
               DO IIO=IJKW(10,IW),IJKW(13,IW)
                  WW_OTHER = WW_OTHER + OM_WW(IIO,JJO,KKO-1)*M2%DX(IIO)*M2%DY(JJO)/DA_OTHER
               ENDDO
            ENDDO
         ENDDO
         WW_AVG = 0.5_EB*(WW(II,JJ,KBAR) + WW_OTHER)
         IF (PREDICTOR) D_CORR(IW) = DS_CORR(IW) - 0.5*(WW_AVG-WW(II,JJ,KBAR))*RDZ(KBAR)
         IF (CORRECTOR) DS_CORR(IW) = -(WW_AVG-WW(II,JJ,KBAR))*RDZ(KBAR)
         UVW_SAVE(IW)   = WW(II,JJ,KBAR)
         WW(II,JJ,KBAR) = WW_AVG
         
   END SELECT

ENDDO EXTERNAL_WALL_LOOP
!$OMP END PARALLEL DO

TUSED(4,NM)=TUSED(4,NM)+SECOND()-TNOW
END SUBROUTINE MATCH_VELOCITY


SUBROUTINE CHECK_STABILITY(NM,CODE)
 
! Checks the Courant and Von Neumann stability criteria, and if necessary, reduces the time step accordingly

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_HEAT 
INTEGER, INTENT(IN) :: NM,CODE
REAL(EB) :: UODX,VODY,WODZ,UVW,UVWMAX,R_DX2,MU_MAX,MUTRM,CP,YY_GET(1:N_SPECIES)
INTEGER  :: I,J,K,IW,IIG,JJG,KKG,ITMP
REAL(EB) :: P_UVWMAX,P_MU_MAX,P_MU_TMP !private variables for OpenMP-Code
INTEGER  :: P_ICFL,P_JCFL,P_KCFL,P_I_VN,P_J_VN,P_K_VN !private variables for OpenMP-Code
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL(),RHOP=>NULL(),DP=>NULL(),MUP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: YYP=>NULL()

IF (EVACUATION_ONLY(NM)) THEN
   CHANGE_TIME_STEP(NM) = .FALSE.
   RETURN
ENDIF

SELECT CASE(CODE)
   CASE(1)
      UU => MESHES(NM)%U
      VV => MESHES(NM)%V
      WW => MESHES(NM)%W
      RHOP => MESHES(NM)%RHO
      DP => MESHES(NM)%D
      YYP => MESHES(NM)%YY
   CASE(2)
      UU => MESHES(NM)%US
      VV => MESHES(NM)%VS
      WW => MESHES(NM)%WS
      RHOP => MESHES(NM)%RHOS
      DP => MESHES(NM)%DS
      YYP => MESHES(NM)%YYS
END SELECT
 
CHANGE_TIME_STEP(NM) = .FALSE.
UVWMAX = 0._EB
VN     = 0._EB
MUTRM  = 1.E-9_EB
R_DX2  = 1.E-9_EB

! Strategy for OpenMP version of CFL/VN number determination
! - find max CFL/VN number for each thread (P_UVWMAX/P_MU_MAX)
! - save I,J,K of each P_UVWMAX/P_MU_MAX in P_ICFL... for each thread
! - compare sequentially all P_UVWMAX/P_MU_MAX and find the global maximum
! - save P_ICFL... of the "winning" thread in the global ICFL... variable
 
! Determine max CFL number from all grid cells

SELECT_VELOCITY_NORM: SELECT CASE (CFL_VELOCITY_NORM)
   CASE(0)
      P_UVWMAX = UVWMAX
      !$OMP PARALLEL DEFAULT(NONE) PRIVATE(P_ICFL,P_JCFL,P_KCFL) &
      !$OMP FIRSTPRIVATE(P_UVWMAX) SHARED(UVWMAX,ICFL,JCFL,KCFL,UU,VV,WW,RDXN,RDYN,RDZN,IBAR,JBAR,KBAR,DP)
      !$OMP DO COLLAPSE(3) PRIVATE(K,J,I,UODX,VODY,WODZ,UVW)
      DO K=0,KBAR
         DO J=0,JBAR
            DO I=0,IBAR
               UODX = ABS(UU(I,J,K))*RDXN(I)
               VODY = ABS(VV(I,J,K))*RDYN(J)
               WODZ = ABS(WW(I,J,K))*RDZN(K)
               UVW  = MAX(UODX,VODY,WODZ) + ABS(DP(I,J,K))
               IF (UVW>=P_UVWMAX) THEN
                  P_UVWMAX = UVW
                  P_ICFL = I
                  P_JCFL = J
                  P_KCFL = K
               ENDIF
            ENDDO
         ENDDO
      ENDDO
      !$OMP END DO NOWAIT
      !$OMP CRITICAL
      IF (P_UVWMAX>=UVWMAX) THEN
         UVWMAX = P_UVWMAX
         ICFL=P_ICFL
         JCFL=P_JCFL
         KCFL=P_KCFL
      ENDIF
      !$OMP END CRITICAL
      !$OMP END PARALLEL
   CASE(1)
      P_UVWMAX = UVWMAX
      !$OMP PARALLEL DEFAULT(NONE) PRIVATE(P_ICFL,P_JCFL,P_KCFL) &
      !$OMP FIRSTPRIVATE(P_UVWMAX) SHARED(UVWMAX,IBM_UVWMAX,ICFL,JCFL,KCFL,UU,VV,WW,RDXN,RDYN,RDZN,IBAR,JBAR,KBAR,DP)
      !$OMP DO COLLAPSE(3) PRIVATE(K,J,I,UVW)
      DO K=0,KBAR
         DO J=0,JBAR
            DO I=0,IBAR
               !!UVW = (ABS(UU(I,J,K)) + ABS(VV(I,J,K)) + ABS(WW(I,J,K)))*MAX(RDXN(I),RDYN(J),RDZN(K))
               UVW = ABS(UU(I,J,K)*RDXN(I)) + ABS(VV(I,J,K)*RDYN(J)) + ABS(WW(I,J,K)*RDZN(K))
               UVW = UVW + IBM_UVWMAX + ABS(DP(I,J,K))
               IF (UVW>=P_UVWMAX) THEN
                  P_UVWMAX = UVW
                  P_ICFL=I
                  P_JCFL=J
                  P_KCFL=K
               ENDIF
            ENDDO
         ENDDO
      ENDDO
      !$OMP END DO NOWAIT
      !$OMP CRITICAL
      IF (P_UVWMAX>=UVWMAX) THEN
         UVWMAX = P_UVWMAX
         ICFL=P_ICFL
         JCFL=P_JCFL
         KCFL=P_KCFL
      ENDIF
      !$OMP END CRITICAL
      !$OMP END PARALLEL
   CASE(2)
      P_UVWMAX = UVWMAX
      !$OMP PARALLEL DEFAULT(NONE) PRIVATE(P_ICFL,P_JCFL,P_KCFL) &
      !$OMP FIRSTPRIVATE(P_UVWMAX) SHARED(UVWMAX,IBM_UVWMAX,ICFL,JCFL,KCFL,UU,VV,WW,RDXN,RDYN,RDZN,IBAR,JBAR,KBAR,DP)
      !$OMP DO COLLAPSE(3) PRIVATE(K,J,I,UVW)
      DO K=0,KBAR
         DO J=0,JBAR
            DO I=0,IBAR
               !!UVW = SQRT(UU(I,J,K)**2 + VV(I,J,K)**2 + WW(I,J,K)**2)*MAX(RDXN(I),RDYN(J),RDZN(K))
               UVW = SQRT( (UU(I,J,K)*RDXN(I))**2 + (VV(I,J,K)*RDYN(J))**2 + (WW(I,J,K)*RDZN(K))**2 )
               UVW = UVW + IBM_UVWMAX + ABS(DP(I,J,K))
               IF (UVW>=P_UVWMAX) THEN
                  P_UVWMAX = UVW
                  P_ICFL=I
                  P_JCFL=J
                  P_KCFL=K
               ENDIF
            ENDDO
         ENDDO
      ENDDO
      !$OMP END DO NOWAIT
      !$OMP CRITICAL
      IF (P_UVWMAX>=UVWMAX) THEN
         UVWMAX = P_UVWMAX
         ICFL=P_ICFL
         JCFL=P_JCFL
         KCFL=P_KCFL
      ENDIF
      !$OMP END CRITICAL
      !$OMP END PARALLEL
END SELECT SELECT_VELOCITY_NORM

WALL_LOOP: DO IW=1,NWC
   IF (BOUNDARY_TYPE(IW)/=SOLID_BOUNDARY) CYCLE WALL_LOOP
   IIG = IJKW(6,IW)
   JJG = IJKW(7,IW)
   KKG = IJKW(8,IW)
   ITMP = MIN(5000,NINT(TMP(IIG,JJG,KKG)))
   IF (N_SPECIES > 0) THEN
      YY_GET = YYP(IIG,JJG,KKG,:)
      CALL GET_SPECIFIC_HEAT(YY_GET,CP,ITMP)
   ELSE
      CP = Y2CP_C(ITMP)
   ENDIF
   UVW = 2._EB*HEAT_TRANS_COEF(IW)/(RHOP(IIG,JJG,KKG)*CP)*RDN(IW)
   IF (UVW>=UVWMAX) THEN
      UVWMAX = UVW
      ICFL=IIG
      JCFL=JJG
      KCFL=KKG
   ENDIF
ENDDO WALL_LOOP

CFL = DT*UVWMAX
 
! Determine max Von Neumann Number for fine grid calcs
 
PARABOLIC_IF: IF (DNS .OR. CHECK_VN) THEN
 
   INCOMPRESSIBLE_IF: IF (DNS .AND. ISOTHERMAL .AND. N_SPECIES==0) THEN
      IF (TWO_D) THEN
         R_DX2 = 1._EB/DXMIN**2 + 1._EB/DZMIN**2
      ELSE
         R_DX2 = 1._EB/DXMIN**2 + 1._EB/DYMIN**2 + 1._EB/DZMIN**2
      ENDIF
      MUTRM = MAX(RPR,RSC)*Y2MU_C(NINT(TMPA))*SPECIES(0)%MW
   ELSE INCOMPRESSIBLE_IF
      MU_MAX = 0._EB
      P_MU_MAX = MU_MAX
      MUP => MU
      !$OMP PARALLEL PRIVATE(P_I_VN,P_J_VN,P_K_VN,P_MU_TMP) FIRSTPRIVATE(P_MU_MAX)
      !$OMP DO COLLAPSE(3) PRIVATE(K,J,I)
      DO K=1,KBAR
         DO J=1,JBAR
            IILOOP_OpenMP: DO I=1,IBAR
               IF (SOLID(CELL_INDEX(I,J,K))) CYCLE IILOOP_OpenMP
               P_MU_TMP = MUP(I,J,K)/RHOP(I,J,K)
               IF (P_MU_TMP>=P_MU_MAX) THEN
                  P_MU_MAX = P_MU_TMP
                  P_I_VN=I
                  P_J_VN=J
                  P_K_VN=K
               ENDIF
            ENDDO IILOOP_OpenMP
         ENDDO
      ENDDO
      !$OMP END DO NOWAIT
      !$OMP CRITICAL
      IF (P_MU_MAX>=MU_MAX) THEN
         MU_MAX = P_MU_MAX
         I_VN=P_I_VN
         J_VN=P_J_VN
         K_VN=P_K_VN
      ENDIF
      !$OMP END CRITICAL
      !$OMP END PARALLEL
      
      IF (TWO_D) THEN
         R_DX2 = RDX(I_VN)**2 + RDZ(K_VN)**2
      ELSE
         R_DX2 = RDX(I_VN)**2 + RDY(J_VN)**2 + RDZ(K_VN)**2
      ENDIF
      MUTRM = MAX(RPR,RSC)*MU_MAX
   ENDIF INCOMPRESSIBLE_IF
 
   VN = DT*2._EB*R_DX2*MUTRM
 
ENDIF PARABOLIC_IF
 
! Adjust time step size if necessary
 
IF ((CFL<CFL_MAX.AND.VN<VN_MAX) .OR. LOCK_TIME_STEP) THEN
   DT_NEXT = DT
   IF (CFL<=CFL_MIN .AND. VN<VN_MIN .AND. .NOT.LOCK_TIME_STEP) THEN
      IF (     RESTRICT_TIME_STEP) DT_NEXT = MIN(1.1_EB*DT,DT_INIT)
      IF (.NOT.RESTRICT_TIME_STEP) DT_NEXT =     1.1_EB*DT
   ENDIF
ELSE
   IF (UVWMAX==0._EB) UVWMAX = 1._EB
   DT = 0.9_EB*MIN( CFL_MAX/UVWMAX , VN_MAX/(2._EB*R_DX2*MUTRM) )
   CHANGE_TIME_STEP(NM) = .TRUE.
ENDIF

IF (PARTICLE_CFL .AND. PART_CFL>PARTICLE_CFL_MAX .AND. .NOT.LOCK_TIME_STEP) THEN
   DT = (PARTICLE_CFL_MAX/PART_CFL)*DT
   DT_NEXT = DT
ENDIF
 
END SUBROUTINE CHECK_STABILITY
 
 

SUBROUTINE BAROCLINIC_CORRECTION
 
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL(),RHOP=>NULL(),HP=>NULL(),RHMK=>NULL(),RRHO=>NULL()
INTEGER  :: I,J,K,IC1,IC2

RHMK => WORK1 ! rho*(H-K)
RRHO => WORK2 ! reciprocal of rho
 
IF (PREDICTOR) THEN
   UU => U
   VV => V
   WW => W
   RHOP=>RHO
   HP => H
ELSE
   UU => US
   VV => VS
   WW => WS
   RHOP=>RHOS
   HP => HS
ENDIF
 
DO K=0,KBP1
   DO J=0,JBP1
      DO I=0,IBP1         
         RHMK(I,J,K) = RHOP(I,J,K)*(HP(I,J,K)-KRES(I,J,K))
         RRHO(I,J,K) = 1._EB/RHOP(I,J,K)
      ENDDO
   ENDDO
ENDDO

DO K=1,KBAR
   DO J=1,JBAR
      DO I=0,IBAR
         IC1 = CELL_INDEX(I,J,K)
         IC2 = CELL_INDEX(I+1,J,K)
         IF (SOLID(IC1) .OR. SOLID(IC2)) CYCLE
         FVX(I,J,K) = FVX(I,J,K) - 0.5_EB*(RHMK(I,J,K)+RHMK(I+1,J,K))*(RRHO(I+1,J,K)-RRHO(I,J,K))*RDXN(I)
      ENDDO
   ENDDO
ENDDO
 
IF (.NOT.TWO_D) THEN
   DO K=1,KBAR
      DO J=0,JBAR
         DO I=1,IBAR
            IC1 = CELL_INDEX(I,J,K)
            IC2 = CELL_INDEX(I,J+1,K)
            IF (SOLID(IC1) .OR. SOLID(IC2)) CYCLE
            FVY(I,J,K) = FVY(I,J,K) - 0.5_EB*(RHMK(I,J,K)+RHMK(I,J+1,K))*(RRHO(I,J+1,K)-RRHO(I,J,K))*RDYN(J)
         ENDDO
      ENDDO
   ENDDO
ENDIF

DO K=0,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IC1 = CELL_INDEX(I,J,K)
         IC2 = CELL_INDEX(I,J,K+1)
         IF (SOLID(IC1) .OR. SOLID(IC2)) CYCLE
         FVZ(I,J,K) = FVZ(I,J,K) - 0.5_EB*(RHMK(I,J,K)+RHMK(I,J,K+1))*(RRHO(I,J,K+1)-RRHO(I,J,K))*RDZN(K)
      ENDDO
   ENDDO
ENDDO
 
END SUBROUTINE BAROCLINIC_CORRECTION


!===========================================================================
! The following are experimental routines for implementation of a second-
! order immersed boundary method (IBM). ~RJM
!===========================================================================

SUBROUTINE IBM_VELOCITY_FLUX(NM)

USE COMPLEX_GEOMETRY, ONLY: VELTAN2D,TRILINEAR,GETX,GETU,GETGRAD

INTEGER, INTENT(IN) :: NM
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL(),DP=>NULL(),RHOP=>NULL(),PP=>NULL(), &
                                       UBAR=>NULL(),VBAR=>NULL(),WBAR=>NULL(),DUDX=>NULL(),DVDY=>NULL(),&
                                       DWDZ=>NULL(),DUDZ=>NULL(),DWDX=>NULL()
REAL(EB) :: U_IBM,V_IBM,W_IBM,VEL2,DN
REAL(EB) :: U_ROT,V_ROT,W_ROT
REAL(EB) :: PE,PW,PT,PB
REAL(EB) :: U_DATA(0:1,0:1,0:1),XI(3),DXI(3),DXC(3),XVEL(3),XGEOM(3),XCELL(3),XNODE(3),XG(3)
REAL(EB) :: U_VEC(2),U_GEOM(2),N_VEC(2),DIVU,GRADU(2,2),GRADP(2),TAU_IJ(2,2),RRHO,MUA
INTEGER :: I,J,K,NG,IJK(3),I_VEL,IP1,IM1,JP1,JM1,KP1,KM1
TYPE(GEOMETRY_TYPE), POINTER :: G=>NULL()

! References:
!
! E.A. Fadlun, R. Verzicco, P. Orlandi, and J. Mohd-Yusof. Combined Immersed-
! Boundary Finite-Difference Methods for Three-Dimensional Complex Flow
! Simulations. J. Comp. Phys. 161:35-60, 2000.
!
! R. McDermott, G. Forney, C. Cruz, and K. McGrattan. A second-order immersed
! boundary method with near-wall physics. APS/DFD Annual Meeting, Minneapolis,
! MN, Nov. 2009.
 
IF (PREDICTOR) THEN
   UU => U
   VV => V
   WW => W
   DP => D
   RHOP => RHO
ELSE
   UU => US
   VV => VS
   WW => WS
   DP => DS
   RHOP => RHOS
ENDIF

IF (IMMERSED_BOUNDARY_METHOD==2) THEN
   PP => WORK1
   UBAR => IBM_SAVE3
   VBAR => IBM_SAVE4
   WBAR => IBM_SAVE5
   DUDX => WORK5
   DVDY => WORK6
   DWDZ => WORK7
   PP = 0._EB
   UBAR = 0._EB
   VBAR = 0._EB
   WBAR = 0._EB
   DO K=0,KBP1
      DO J=0,JBP1
         DO I=0,IBP1
         
            IM1 = MAX(I-1,0)   
            JM1 = MAX(J-1,0)
            KM1 = MAX(K-1,0)

            UBAR(I,J,K) = 0.5_EB*(UU(I,J,K)+UU(IM1,J,K))
            VBAR(I,J,K) = 0.5_EB*(VV(I,J,K)+VV(I,JM1,K))
            WBAR(I,J,K) = 0.5_EB*(WW(I,J,K)+WW(I,J,KM1))
            
            VEL2 = UBAR(I,J,K)**2+VBAR(I,J,K)**2+WBAR(I,J,K)**2
            PP(I,J,K) = RHOP(I,J,K)*(H(I,J,K)-.5_EB*VEL2)
            
            DUDX(I,J,K) = (UU(I,J,K)-UU(IM1,J,K))/DX(I)
            DVDY(I,J,K) = (VV(I,J,K)-VV(I,JM1,K))/DY(J)
            DWDZ(I,J,K) = (WW(I,J,K)-WW(I,J,KM1))/DZ(K)
         ENDDO
      ENDDO
   ENDDO
   
   DUDZ => IBM_SAVE1
   DWDX => IBM_SAVE2
ENDIF

GEOM_LOOP: DO NG=1,N_GEOM

   G => GEOMETRY(NG)
   
   IF ( G%MAX_I(NM)<G%MIN_I(NM) .OR. &
        G%MAX_J(NM)<G%MIN_J(NM) .OR. &
        G%MAX_K(NM)<G%MIN_K(NM) ) CYCLE GEOM_LOOP
   
   XGEOM = (/G%X,G%Y,G%Z/)
   
   DO K=G%MIN_K(NM),G%MAX_K(NM)
      DO J=G%MIN_J(NM),G%MAX_J(NM)
         DO I=G%MIN_I(NM),G%MAX_I(NM)
            IF (G%U_MASK(I,J,K)==1) CYCLE ! point is in gas phase
         
            IJK   = (/I,J,K/)
            XVEL  = (/X(I),YC(J),ZC(K)/)
            XCELL = (/XC(I),YC(J),ZC(K)/)
            XNODE = (/X(I),YC(J),Z(K)/)
            DXC   = (/DX(I),DYN(J),DZN(K)/)
  
            SELECT CASE(G%U_MASK(I,J,K))
               CASE(-1)
                  U_ROT = (XVEL(3)-XGEOM(3))*G%OMEGA_Y - (XVEL(2)-XGEOM(2))*G%OMEGA_Z
                  U_IBM = G%U + U_ROT
               CASE(0)
                  SELECT_METHOD1: SELECT CASE(IMMERSED_BOUNDARY_METHOD)
                     CASE(0)
                        CYCLE ! treat as gas phase cell
                     CASE(1)
                        U_ROT = (XVEL(3)-XGEOM(3))*G%OMEGA_Y - (XVEL(2)-XGEOM(2))*G%OMEGA_Z
                        CALL GETX(XI,XVEL,NG)
                        CALL GETU(U_DATA,DXI,XI,XVEL,IJK,1,NM)
                        U_IBM = TRILINEAR(U_DATA,DXI,DXC)
                        U_IBM = 0.5_EB*(U_IBM+(G%U+U_ROT))
                     CASE(2)
                        IP1 = MIN(I+1,IBP1)
                        JP1 = MIN(J+1,JBP1)
                        KP1 = MIN(K+1,KBP1)
                        IM1 = MAX(I-1,0)
                        JM1 = MAX(J-1,0)
                        KM1 = MAX(K-1,0)
 
                        CALL GETX(XI,XVEL,NG)
                        XG    = XVEL-(XI-XVEL)                  ! point on the surface of geometry
                        N_VEC = (/XVEL(1)-XG(1),XVEL(3)-XG(3)/) ! normal from surface to velocity point
                        DN    = SQRT(DOT_PRODUCT(N_VEC,N_VEC))  ! distance
                        N_VEC = N_VEC/DN                        ! unit normal
                        
                        U_VEC  = (/UU(I,J,K),0.5_EB*(WBAR(I,J,K)+WBAR(IP1,J,K))/)
                        U_ROT  = (XG(3)-XGEOM(3))*G%OMEGA_Y - (XG(2)-XGEOM(2))*G%OMEGA_Z
                        W_ROT  = (XG(2)-XGEOM(2))*G%OMEGA_X - (XG(1)-XGEOM(1))*G%OMEGA_Y
                        U_GEOM = (/G%U+U_ROT,G%W+W_ROT/)

                        DIVU = 0.5_EB*(DP(I,J,K)+DP(IP1,J,K))
                        
                        ! compute GRADU at point XI
                        CALL GETGRAD(U_DATA,DXI,XI,XCELL,IJK,1,1,NM); GRADU(1,1) = TRILINEAR(U_DATA,DXI,DXC)
                        CALL GETGRAD(U_DATA,DXI,XI,XCELL,IJK,2,2,NM); GRADU(2,2) = TRILINEAR(U_DATA,DXI,DXC)
                        CALL GETGRAD(U_DATA,DXI,XI,XNODE,IJK,1,2,NM); GRADU(1,2) = TRILINEAR(U_DATA,DXI,DXC)
                        CALL GETGRAD(U_DATA,DXI,XI,XNODE,IJK,2,1,NM); GRADU(2,1) = TRILINEAR(U_DATA,DXI,DXC)
                        
                        ! compute GRADP at point XVEL
                        PE = PP(IP1,J,K)
                        PW = PP(I,J,K)
                        PT = 0.25_EB*(PP(I,J,K)+PP(IP1,J,K)+PP(I,J,KP1)+PP(IP1,J,KP1))
                        PB = 0.25_EB*(PP(I,J,K)+PP(IP1,J,K)+PP(I,J,KM1)+PP(IP1,J,KM1))
                  
                        GRADP(1) = (PE-PW)/DXN(I)
                        GRADP(2) = (PT-PB)/DZ(K)
 
                        RRHO  = 2._EB/(RHOP(I,J,K)+RHOP(IP1,J,K))
                        MUA = 0.5_EB*(MU(I,J,K)+MU(IP1,J,K))
                  
                        TAU_IJ(1,1) = -MUA*(GRADU(1,1)-TWTH*DIVU)
                        TAU_IJ(2,2) = -MUA*(GRADU(2,2)-TWTH*DIVU)
                        TAU_IJ(1,2) = -MUA*(GRADU(1,2)+GRADU(2,1))
                        TAU_IJ(2,1) = TAU_IJ(1,2)
                  
                        I_VEL = 1

                        !U_IBM = UU(I,J,K)
                        MUA = 0.5_EB*(MU_DNS(I,J,K)+MU_DNS(IP1,J,K))
                        U_IBM = VELTAN2D(U_VEC,U_GEOM,N_VEC,DN,DIVU,GRADU,GRADP,TAU_IJ,DT,RRHO,MUA,I_VEL)
                  END SELECT SELECT_METHOD1
            END SELECT
      
            FVX(I,J,K) = -RDXN(I)*(H(I+1,J,K)-H(I,J,K)) - (U_IBM-UU(I,J,K))/DT
        
         ENDDO
      ENDDO
   ENDDO
   
   IF (.NOT.TWO_D) THEN
      DO K=G%MIN_K(NM),G%MAX_K(NM)
         DO J=G%MIN_J(NM),G%MAX_J(NM)
            DO I=G%MIN_I(NM),G%MAX_I(NM)
               IF (G%V_MASK(I,J,K)==1) CYCLE ! point is in gas phase
         
               IJK  = (/I,J,K/)
               XVEL = (/XC(I),Y(J),ZC(K)/)
         
               SELECT CASE(G%V_MASK(I,J,K))
                  CASE(-1)
                     V_ROT = (XVEL(1)-XGEOM(1))*G%OMEGA_Z - (XVEL(3)-XGEOM(3))*G%OMEGA_X
                     V_IBM = G%V + V_ROT
                  CASE(0)
                     SELECT_METHOD2: SELECT CASE(IMMERSED_BOUNDARY_METHOD)
                        CASE(0)
                           CYCLE
                        CASE(1:2)
                           V_ROT = (XVEL(1)-XGEOM(1))*G%OMEGA_Z - (XVEL(3)-XGEOM(3))*G%OMEGA_X
                           CALL GETX(XI,XVEL,NG)
                           CALL GETU(U_DATA,DXI,XI,XVEL,IJK,2,NM)
                           DXC = (/DXN(I),DY(J),DZN(K)/)
                           V_IBM = TRILINEAR(U_DATA,DXI,DXC)
                           V_IBM = 0.5_EB*(V_IBM+(G%V+V_ROT))
                        !CASE(2)
                        !   V_IBM = G%V + V_ROT
                     END SELECT SELECT_METHOD2
               END SELECT
         
               FVY(I,J,K) = -RDYN(J)*(H(I,J+1,K)-H(I,J,K)) - (V_IBM-VV(I,J,K))/DT
         
            ENDDO
         ENDDO 
      ENDDO
   ENDIF
   
   DO K=G%MIN_K(NM),G%MAX_K(NM)
      DO J=G%MIN_J(NM),G%MAX_J(NM)
         DO I=G%MIN_I(NM),G%MAX_I(NM)
            IF (G%W_MASK(I,J,K)==1) CYCLE
         
            IJK   = (/I,J,K/)
            XVEL  = (/XC(I),YC(J),Z(K)/)
            XCELL = (/XC(I),YC(J),ZC(K)/)
            XNODE = (/X(I),YC(J),Z(K)/)
            DXC   = (/DXN(I),DYN(J),DZ(K)/)
            
            SELECT CASE(G%W_MASK(I,J,K))
               CASE(-1)
                  W_ROT = (XVEL(2)-XGEOM(2))*G%OMEGA_X - (XVEL(1)-XGEOM(1))*G%OMEGA_Y
                  W_IBM = G%W + W_ROT
               CASE(0)
                  SELECT_METHOD3: SELECT CASE(IMMERSED_BOUNDARY_METHOD)
                     CASE(0)
                        CYCLE
                     CASE(1)
                        W_ROT = (XVEL(2)-XGEOM(2))*G%OMEGA_X - (XVEL(1)-XGEOM(1))*G%OMEGA_Y
                        CALL GETX(XI,XVEL,NG)
                        CALL GETU(U_DATA,DXI,XI,XVEL,IJK,3,NM)
                        W_IBM = TRILINEAR(U_DATA,DXI,DXC)
                        W_IBM = 0.5_EB*(W_IBM+(G%W+W_ROT))
                     CASE(2)
                        IP1 = MIN(I+1,IBP1)
                        JP1 = MIN(J+1,JBP1)
                        KP1 = MIN(K+1,KBP1)
                        IM1 = MAX(I-1,0)
                        JM1 = MAX(J-1,0)
                        KM1 = MAX(K-1,0)
                                                
                        CALL GETX(XI,XVEL,NG)
                        XG    = XVEL-(XI-XVEL)                  ! point on the surface of geometry
                        N_VEC = (/XVEL(1)-XG(1),XVEL(3)-XG(3)/) ! normal from surface to velocity point
                        DN    = SQRT(DOT_PRODUCT(N_VEC,N_VEC))  ! distance
                        N_VEC = N_VEC/DN                        ! unit normal
                        
                        U_VEC  = (/0.5_EB*(UBAR(I,J,K)+UBAR(I,J,KP1)),WW(I,J,K)/)
                        U_ROT  = (XG(3)-XGEOM(3))*G%OMEGA_Y - (XG(2)-XGEOM(2))*G%OMEGA_Z
                        W_ROT  = (XG(2)-XGEOM(2))*G%OMEGA_X - (XG(1)-XGEOM(1))*G%OMEGA_Y
                        U_GEOM = (/G%U+U_ROT,G%W+W_ROT/)
                        
                        DIVU = 0.5_EB*(DP(I,J,K)+DP(I,J,KP1))
                       
                        ! compute GRADU at point XI
                        CALL GETGRAD(U_DATA,DXI,XI,XCELL,IJK,1,1,NM); GRADU(1,1) = TRILINEAR(U_DATA,DXI,DXC)
                        CALL GETGRAD(U_DATA,DXI,XI,XCELL,IJK,2,2,NM); GRADU(2,2) = TRILINEAR(U_DATA,DXI,DXC)
                        CALL GETGRAD(U_DATA,DXI,XI,XNODE,IJK,1,2,NM); GRADU(1,2) = TRILINEAR(U_DATA,DXI,DXC)
                        CALL GETGRAD(U_DATA,DXI,XI,XNODE,IJK,2,1,NM); GRADU(2,1) = TRILINEAR(U_DATA,DXI,DXC)
                  
                        ! compute GRADP at point XVEL
                        PE = 0.25_EB*(PP(I,J,K)+PP(I,J,KP1)+PP(IP1,J,K)+PP(IP1,J,KP1))
                        PW = 0.25_EB*(PP(I,J,K)+PP(I,J,KP1)+PP(IM1,J,K)+PP(IM1,J,KP1))
                        PT = PP(I,J,KP1)
                        PB = PP(I,J,K)
                  
                        GRADP(1) = (PE-PW)/DX(I)
                        GRADP(2) = (PT-PB)/DZN(K)
 
                        RRHO  = 2._EB/(RHOP(I,J,K)+RHOP(I,J,KP1))
                        MUA = 0.5_EB*(MU(I,J,K)+MU(I,J,KP1))
                  
                        TAU_IJ(1,1) = -MUA*(GRADU(1,1)-TWTH*DIVU)
                        TAU_IJ(2,2) = -MUA*(GRADU(2,2)-TWTH*DIVU)
                        TAU_IJ(1,2) = -MUA*(GRADU(1,2)+GRADU(2,1))
                        TAU_IJ(2,1) = TAU_IJ(1,2)
                  
                        I_VEL = 2 ! will change when we go to 3D
                  
                        !W_IBM = WW(I,J,K)
                        MUA = 0.5_EB*(MU_DNS(I,J,K)+MU_DNS(I,J,KP1))
                        W_IBM = VELTAN2D(U_VEC,U_GEOM,N_VEC,DN,DIVU,GRADU,GRADP,TAU_IJ,DT,RRHO,MUA,I_VEL)
                  END SELECT SELECT_METHOD3
            END SELECT
         
            FVZ(I,J,K) = -RDZN(K)*(H(I,J,K+1)-H(I,J,K)) - (W_IBM-WW(I,J,K))/DT
         
         ENDDO
      ENDDO
   ENDDO
   
ENDDO GEOM_LOOP

END SUBROUTINE IBM_VELOCITY_FLUX


SUBROUTINE GET_REV_velo(MODULE_REV,MODULE_DATE)
INTEGER,INTENT(INOUT) :: MODULE_REV
CHARACTER(255),INTENT(INOUT) :: MODULE_DATE

WRITE(MODULE_DATE,'(A)') velorev(INDEX(velorev,':')+1:LEN_TRIM(velorev)-2)
READ (MODULE_DATE,'(I5)') MODULE_REV
WRITE(MODULE_DATE,'(A)') velodate

END SUBROUTINE GET_REV_velo
 
END MODULE VELO
