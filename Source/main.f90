!> \brief FDS is a computational fluid dynamics (CFD) code designed to model
!> fire and other thermal phenomena.

PROGRAM FDS

! Fire Dynamics Simulator, Main Program, Multiple CPU version.

USE PRECISION_PARAMETERS
USE MESH_VARIABLES
USE GLOBAL_CONSTANTS
USE TRAN
USE DUMP
USE READ_INPUT
USE INIT
USE DIVG
USE PRES
USE MASS
USE PART
USE VEGE
USE VELO
USE RAD
USE RADCONS, ONLY : DLN,TIME_STEP_INCREMENT ! include TSI for GENISTELA activation
USE OUTPUT_DATA
USE MEMORY_FUNCTIONS
USE HVAC_ROUTINES
USE COMP_FUNCTIONS, ONLY : CURRENT_TIME,GET_FILE_NUMBER,APPEND_FILE ! include latter two for GENISTELA output files
USE DEVICE_VARIABLES
USE WALL_ROUTINES
USE FIRE
USE CONTROL_FUNCTIONS
USE EVAC
USE TURBULENCE, ONLY: NS_ANALYTICAL_SOLUTION,INIT_TURB_ARRAYS,COMPRESSION_WAVE,&
                      TWOD_VORTEX_CERFACS,TWOD_VORTEX_UMD,TWOD_SOBOROT_UMD, &
                      SYNTHETIC_TURBULENCE,SYNTHETIC_EDDY_SETUP,SANDIA_DAT
USE MANUFACTURED_SOLUTIONS, ONLY: SHUNN_MMS_3,SAAD_MMS_1
USE COMPLEX_GEOMETRY, ONLY: INIT_CUTCELL_DATA, CCIBM_SET_DATA, CCIBM_END_STEP, FINISH_CCIBM, &
                            LINEARFIELDS_INTERP_TEST, CCREGION_DENSITY, &
                            CHECK_SPEC_TRANSPORT_CONSERVE,MASS_CONSERVE_INIT,CCIBM_RHO0W_INTERP,&
                            CCCOMPUTE_RADIATION,CCIBM_VELOCITY_FLUX,CCIBM_NO_FLUX,CCIBM_COMPUTE_VELOCITY_ERROR,&
                            CCIBM_TARGET_VELOCITY,ROTATED_CUBE_ANN_SOLN,MESH_CC_EXCHANGE2
USE OPENMP
USE MPI
USE SCRC, ONLY: SCARC_SETUP, SCARC_SOLVER
USE SOOT_ROUTINES, ONLY: CALC_AGGLOMERATION
USE GLOBALMATRIX_SOLVER, ONLY : GLMAT_SOLVER_SETUP_H, GLMAT_SOLVER_H, COPY_H_OMESH_TO_MESH,FINISH_GLMAT_SOLVER_H

IMPLICIT NONE

! Miscellaneous declarations

LOGICAL  :: EX=.FALSE.,DIAGNOSTICS,EXCHANGE_EVACUATION=.FALSE.,CTRL_STOP_STATUS,CHECK_FREEZE_VELOCITY=.TRUE.
INTEGER  :: LO10,NM,IZERO,ANG_INC_COUNTER,PZ_CODE
REAL(EB) :: T,DT,DT_EVAC,TNOW
REAL :: CPUTIME
REAL(EB), ALLOCATABLE, DIMENSION(:) ::  TC_GLB,TC_LOC,DT_NEW,TI_LOC,TI_GLB, &
                                        DSUM_ALL,PSUM_ALL,USUM_ALL,DSUM_ALL_LOCAL,PSUM_ALL_LOCAL,USUM_ALL_LOCAL
REAL(EB), ALLOCATABLE, DIMENSION(:,:) ::  TC2_GLB,TC2_LOC
LOGICAL, ALLOCATABLE, DIMENSION(:,:) :: CONNECTED_ZONES_GLOBAL,CONNECTED_ZONES_LOCAL
LOGICAL, ALLOCATABLE, DIMENSION(:) ::  STATE_GLB,STATE_LOC
INTEGER :: NOM,IWW,IW,ITER
TYPE (MESH_TYPE), POINTER :: M,M4
TYPE (OMESH_TYPE), POINTER :: M2,M3,M5
LOGICAL :: TIMEHIST = .FALSE.  ! allow time history to be taken for GeniSTELA
CHARACTER(80) :: CSVHFMT  ! header format for GENISTELA temperature output

! MPI stuff

INTEGER :: N,I,IERR=0,STATUS(MPI_STATUS_SIZE)
INTEGER :: PNAMELEN=0,TAG_EVAC
INTEGER :: PROVIDED
INTEGER, PARAMETER :: REQUIRED=MPI_THREAD_FUNNELED
INTEGER, ALLOCATABLE, DIMENSION(:) :: REQ,REQ1,REQ2,REQ3,REQ4,REQ5,REQ7,REQ6,REQ8,REQ14,COUNTS,DISPLS,&
                                      COUNTS_MASS,DISPLS_MASS,COUNTS_HVAC,DISPLS_HVAC,&
                                      COUNTS_QM_DOT,DISPLS_QM_DOT,COUNTS_TEN,DISPLS_TEN,COUNTS_TWENTY,DISPLS_TWENTY
INTEGER :: N_REQ,N_REQ1=0,N_REQ2=0,N_REQ3=0,N_REQ4=0,N_REQ5=0,N_REQ7=0,N_REQ6=0,N_REQ8=0,N_REQ14=0,N_COMMUNICATIONS
CHARACTER(MPI_MAX_PROCESSOR_NAME) :: PNAME
REAL(EB), ALLOCATABLE, DIMENSION(:)       :: REAL_BUFFER_1
REAL(EB), ALLOCATABLE, DIMENSION(:,:)     :: REAL_BUFFER_2,REAL_BUFFER_3,REAL_BUFFER_5,REAL_BUFFER_6,REAL_BUFFER_8,&
                                             REAL_BUFFER_11,REAL_BUFFER_12,REAL_BUFFER_13,REAL_BUFFER_14

! Initialize OpenMP

CALL OPENMP_INIT

! output version info if fds is invoked without any arguments
! (this must be done before MPI is initialized)

CALL VERSION_INFO

! Initialize MPI (First executable lines of code)

CALL MPI_INIT_THREAD(REQUIRED,PROVIDED,IERR)
CALL MPI_COMM_RANK(MPI_COMM_WORLD, MYID, IERR)
CALL MPI_COMM_SIZE(MPI_COMM_WORLD, N_MPI_PROCESSES, IERR)
CALL MPI_GET_PROCESSOR_NAME(PNAME, PNAMELEN, IERR)

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
IF (MYID==0) WRITE(LU_ERR,'(/A/)') ' Starting FDS ...'
WRITE(LU_ERR,'(A,I6,A,A)') ' MPI Process ',MYID,' started on ',PNAME(1:PNAMELEN)
CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)

! Check that MPI processes and OpenMP threads are working properly

CALL CHECK_MPI

! Start wall clock timing

WALL_CLOCK_START = CURRENT_TIME()
CALL CPU_TIME(CPUTIME)
CPU_TIME_START = CPUTIME
ALLOCATE(T_USED(N_TIMERS)) ; T_USED = 0._EB ; T_USED(1) = CURRENT_TIME()

! Assign a compilation date (All Nodes)

CALL GET_INFO (REVISION,REVISION_DATE,COMPILE_DATE)

! Read input from CHID.fds file and stop the code if any errors are found

CALL READ_DATA(DT)

CALL STOP_CHECK(1)

! If SOLID_HT3D=T in any mesh, then set SOLID_HT3D=T in all meshes.

CALL MPI_ALLREDUCE(MPI_IN_PLACE,SOLID_HT3D,INTEGER_ONE,MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,IERR)

! Setup number of OPENMP threads

CALL OPENMP_SET_THREADS

! Print OPENMP thread status

CALL OPENMP_PRINT_STATUS

! Set up send and receive buffer counts and displacements

CALL MPI_INITIALIZATION_CHORES(1)

! Open and write to Smokeview and status file (Master Node Only)

CALL ASSIGN_FILE_NAMES

DO N=0,N_MPI_PROCESSES-1
   IF (MYID==N) CALL WRITE_SMOKEVIEW_FILE
   IF (N==N_MPI_PROCESSES-1) EXIT
   IF (SHARED_FILE_SYSTEM) CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
ENDDO
CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)

! Shut down the run if it is only for checking the set up

IF (SETUP_ONLY .AND. .NOT.CHECK_MESH_ALIGNMENT) STOP_STATUS = SETUP_ONLY_STOP

! Check for errors and shutdown if found

CALL STOP_CHECK(1)

! MPI process 0 reopens the Smokeview file for additional output

IF (MYID==0) THEN
   OPEN(LU_SMV,FILE=FN_SMV,FORM='FORMATTED', STATUS='OLD',POSITION='APPEND')
   CALL WRITE_STATUS_FILES
ENDIF

! Start the clock

T = T_BEGIN

! Stop all the processes if this is just a set-up run

IF (CHECK_MESH_ALIGNMENT) THEN
   IF (MYID==0) CALL INITIALIZE_DIAGNOSTIC_FILE(DT)
   STOP_STATUS = SETUP_ONLY_STOP
   IF (MYID==0) WRITE(LU_ERR,'(A)') ' Checking mesh alignment. This could take a few tens of seconds...'
ENDIF

! Allocate various utility arrays

CALL MPI_INITIALIZATION_CHORES(2)

! Initialize global parameters

CALL INITIALIZE_GLOBAL_VARIABLES
CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)

! Initialize radiation

IF (RADIATION) CALL INIT_RADIATION

! Allocate and initialize mesh-specific variables, and check to see if the code should stop

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   CALL INITIALIZE_MESH_VARIABLES_1(DT,NM)
ENDDO
CALL STOP_CHECK(1)

! Allocate and initialize OMESH arrays to hold "other mesh" data for a given mesh

N_COMMUNICATIONS = 0

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   CALL INITIALIZE_MESH_EXCHANGE_1(NM)
ENDDO
CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)

! Allocate "request" arrays to keep track of MPI communications

CALL MPI_INITIALIZATION_CHORES(3)

! Exchange information related to size of OMESH arrays

CALL MPI_INITIALIZATION_CHORES(4)

! Initial complex geometry CC setup

IF (CC_IBM) THEN
   CALL CCIBM_SET_DATA(.TRUE.) ! Define Cartesian cell types (used to define pressure zones), cut-cells, cfaces.
   CALL STOP_CHECK(1)
ENDIF

! Initialize PRESSURE_ZONEs

SETUP_PRESSURE_ZONES_INDEX = 0
PZ_CODE = 0
DO WHILE (ANY(SETUP_PRESSURE_ZONES_INDEX==0))
   CALL POST_RECEIVES(11)
   CALL MESH_EXCHANGE(11)
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL SETUP_PRESSURE_ZONES(NM,PZ_CODE)
   ENDDO
   PZ_CODE = 1
   CALL MPI_ALLGATHERV(MPI_IN_PLACE,COUNTS(MYID),MPI_INTEGER,SETUP_PRESSURE_ZONES_INDEX,COUNTS,DISPLS,&
                       MPI_INTEGER,MPI_COMM_WORLD,IERR)
ENDDO

IF (MYID==0 .AND. VERBOSE) WRITE(LU_ERR,'(A)') ' Completed SETUP_PRESSURE_ZONES'

! Allocate and initialize OMESH arrays to hold "other mesh" data for a given mesh

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   CALL INITIALIZE_MESH_EXCHANGE_2(NM)
ENDDO
CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
IF (MYID==0 .AND. VERBOSE) WRITE(LU_ERR,'(A)') ' Completed INITIALIZE_MESH_EXCHANGE_2'

! Exchange CELL_COUNT, the dimension of various arrays related to obstructions

IF (N_MPI_PROCESSES>1) THEN
   CALL MPI_ALLGATHERV(MPI_IN_PLACE,COUNTS(MYID),MPI_INTEGER,CELL_COUNT,COUNTS,DISPLS,MPI_INTEGER,MPI_COMM_WORLD,IERR)
ENDIF

! Initialize persistent MPI sends and receives and allocate buffer arrays.

CALL POST_RECEIVES(0)
CALL MESH_EXCHANGE(0)

! Finish initializing mesh variables

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   CALL INITIALIZE_MESH_VARIABLES_2(NM)
ENDDO
IF (MYID==0 .AND. VERBOSE) WRITE(LU_ERR,'(A)') ' Completed INITIALIZE_MESH_VARIABLES_2'

! Create arrays and communicators to exchange back wall information across mesh boundaries

CALL INITIALIZE_BACK_WALL_EXCHANGE

CALL STOP_CHECK(1)

! Initialize ScaRC solver

IF (PRES_METHOD == 'SCARC' .OR. PRES_METHOD == 'USCARC') THEN
   CALL SCARC_SETUP
   CALL STOP_CHECK(1)
ENDIF

! Initialize turb arrays

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (TGA_SURF_INDEX>0) CYCLE
   CALL INIT_TURB_ARRAYS(NM)
ENDDO

! Final complex geometry CC setup

IF (CC_IBM) THEN
   CALL CCIBM_SET_DATA(.FALSE.) ! Interpolation Stencils, Scalar transport MATVEC data, cface RDNs.
   CALL STOP_CHECK(1)
ENDIF

! Initialize the flow field with random noise to eliminate false symmetries

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (TGA_SURF_INDEX>0 .OR. EVACUATION_ONLY(NM)) CYCLE
   IF (NOISE) CALL INITIAL_NOISE(NM)
   IF (PERIODIC_TEST==1) CALL NS_ANALYTICAL_SOLUTION(NM,T_BEGIN,RK_STAGE=2)
   IF (PERIODIC_TEST==2) CALL UVW_INIT(NM,UVW_FILE)
   IF (PERIODIC_TEST==3) CALL COMPRESSION_WAVE(NM,0._EB,3)
   IF (PERIODIC_TEST==4) CALL COMPRESSION_WAVE(NM,0._EB,4)
   IF (PERIODIC_TEST==6) CALL TWOD_VORTEX_CERFACS(NM)
   IF (PERIODIC_TEST==7) CALL SHUNN_MMS_3(DT,NM)
   IF (PERIODIC_TEST==8) CALL NS_ANALYTICAL_SOLUTION(NM,T_BEGIN,RK_STAGE=2)
   IF (PERIODIC_TEST==9) CALL SANDIA_DAT(NM,UVW_FILE)
   IF (PERIODIC_TEST==10) CALL TWOD_VORTEX_UMD(NM)
   IF (PERIODIC_TEST==11) CALL SAAD_MMS_1(NM)
   IF (PERIODIC_TEST==12) CALL TWOD_SOBOROT_UMD(NM)
   IF (PERIODIC_TEST==13) CALL TWOD_SOBOROT_UMD(NM)
   IF (PERIODIC_TEST==21) CALL ROTATED_CUBE_ANN_SOLN(NM,T_BEGIN) ! No Rotation.
   IF (PERIODIC_TEST==22) CALL ROTATED_CUBE_ANN_SOLN(NM,T_BEGIN) ! 27 deg Rotation.
   IF (PERIODIC_TEST==23) CALL ROTATED_CUBE_ANN_SOLN(NM,T_BEGIN) ! 45 deg Rotation.
   IF (UVW_RESTART)      CALL UVW_INIT(NM,CSVFINFO(NM)%UVWFILE)
ENDDO

IF (CC_IBM) THEN
   CALL INIT_CUTCELL_DATA(T_BEGIN,DT)  ! Init centroid data (i.e. rho,zz) on cut-cells and cut-faces.
   IF (PERIODIC_TEST==101) CALL LINEARFIELDS_INTERP_TEST
ENDIF

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (TGA_SURF_INDEX>0 .OR. EVACUATION_ONLY(NM)) CYCLE
   CALL COMPUTE_VISCOSITY(T_BEGIN,NM,APPLY_TO_ESTIMATED_VARIABLES=.FALSE.) ! needed here for KRES prior to mesh exchange
ENDDO

! Exchange information at mesh boundaries related to the various initialization routines just completed

CALL MESH_EXCHANGE(1)
CALL MESH_EXCHANGE(4)
CALL POST_RECEIVES(6)
CALL MESH_EXCHANGE(6)

! Ensure normal components of velocity match at mesh boundaries and do velocity BCs just in case the flow is not initialized to zero

PREDICTOR = .FALSE.
CORRECTOR = .TRUE.

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (TGA_SURF_INDEX>0 .OR. EVACUATION_ONLY(NM)) CYCLE
   CALL MATCH_VELOCITY(NM)
   CALL COMPUTE_VISCOSITY(T_BEGIN,NM,APPLY_TO_ESTIMATED_VARIABLES=.FALSE.) ! call again after mesh exchange
   IF (SYNTHETIC_EDDY_METHOD) CALL SYNTHETIC_EDDY_SETUP(NM)
   CALL VELOCITY_BC(T_BEGIN,NM,APPLY_TO_ESTIMATED_VARIABLES=.FALSE.)
   CALL VISCOSITY_BC(NM,APPLY_TO_ESTIMATED_VARIABLES=.FALSE.)
ENDDO

! Iterate surface BCs and radiation in case temperatures are not initialized to ambient

DO I=1,INITIAL_RADIATION_ITERATIONS
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NM)) THEN
         IF (MYID==EVAC_PROCESS .AND. RADIATION .AND..NOT.ALL(EVACUATION_ONLY)) EXCHANGE_RADIATION=.TRUE.
         CYCLE
      ENDIF
      CALL WALL_BC(T_BEGIN,DT,NM)
      IF (RADIATION) THEN
         CALL COMPUTE_RADIATION(T_BEGIN,NM,1)
         IF (CC_IBM) CALL CCCOMPUTE_RADIATION(T_BEGIN,NM,1)
      ENDIF
   ENDDO
   DO ANG_INC_COUNTER=1,ANGLE_INCREMENT
      CALL MESH_EXCHANGE(2) ! Exchange radiation intensity at interpolated boundaries
   ENDDO
ENDDO
IF (MYID==0 .AND. VERBOSE) WRITE(LU_ERR,'(A)') ' Initialized Radiation'

IF(CHECK_MASS_CONSERVE) CALL MASS_CONSERVE_INIT
IF (CC_IBM .AND. .NOT.COMPUTE_CUTCELLS_ONLY) CALL CCIBM_RHO0W_INTERP

! Compute divergence just in case the flow field is not initialized to ambient

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (EVACUATION_ONLY(NM)) CYCLE
   CALL DIVERGENCE_PART_1(T_BEGIN,DT,NM)
ENDDO

! Potentially read data from a previous calculation

IF (RESTART) THEN
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL READ_RESTART(T,DT,NM)
   ENDDO
   IF (CC_IBM) CALL INIT_CUTCELL_DATA(T,DT)  ! Init centroid data (i.e. rho,zz) on cut-cells and cut-faces.
   CALL STOP_CHECK(1)
ENDIF

! Initialize particle distributions

CALL GENERATE_PARTICLE_DISTRIBUTIONS

! Level Set model for firespread in vegetation

IF (LEVEL_SET_MODE>0 .OR. TERRAIN_CASE) THEN
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL INITIALIZE_LEVEL_SET_FIRESPREAD_1(NM)
   ENDDO
   CALL MESH_EXCHANGE(14)
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL INITIALIZE_LEVEL_SET_FIRESPREAD_2(NM)
   ENDDO
ENDIF

! Initialize output files that are mesh-specific

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   CALL INSERT_ALL_PARTICLES(T,NM)
   IF (TGA_SURF_INDEX<1) CALL INITIALIZE_DEVICES(NM)
   IF (TGA_SURF_INDEX<1) CALL INITIALIZE_PROFILES(NM)
   IF (TGA_SURF_INDEX<1) CALL INITIALIZE_MESH_DUMPS(NM)
ENDDO
CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
IF (MYID==0 .AND. VERBOSE) WRITE(LU_ERR,'(A)') ' Inserted particles'

! Check for any stop flags at this point in the set up.

CALL STOP_CHECK(1)

! Check to see if only a TGA analysis is to be performed

IF (TGA_SURF_INDEX>0) THEN
   IF (MYID==0) CALL TGA_ANALYSIS
   STOP_STATUS = TGA_ANALYSIS_STOP
   CALL STOP_CHECK(1)
ENDIF

! Initialize output files containing global data (Master Node Only)

IF (MYID==0) THEN
   CALL INITIALIZE_GLOBAL_DUMPS(T,DT)
   IF (VERBOSE) WRITE(LU_ERR,'(A)') ' Called INITIALIZE_GLOBAL_DUMPS'
ENDIF

! Initialize GLMat solver for H:

IF (GLMAT_SOLVER) THEN
   CALL GLMAT_SOLVER_SETUP_H(1)
   CALL STOP_CHECK(1)
   CALL MESH_EXCHANGE(3) ! Exchange guard cell info for CCVAR(I,J,K,CGSC) -> HS.
   CALL GLMAT_SOLVER_SETUP_H(2)
   CALL MESH_EXCHANGE(3) ! Exchange guard cell info for CCVAR(I,J,K,UNKH) -> HS.
   CALL GLMAT_SOLVER_SETUP_H(3)
ENDIF
CALL INIT_EVAC_DUMPS
CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)

! Initialize EVACuation routines

IF (ANY(EVACUATION_ONLY)) THEN
   CALL INITIALIZE_EVAC
   IF (N_MPI_PROCESSES==1 .OR. (N_MPI_PROCESSES>1 .AND. MYID==EVAC_PROCESS)) CALL INIT_EVAC_GROUPS
   IF(ALL(EVACUATION_ONLY)) HVAC_SOLVE=.FALSE.
ENDIF

! Initialize HVAC variables

IF (HVAC_SOLVE) THEN
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NM)) CYCLE
      CALL HVAC_BC_IN(NM)
   ENDDO
   IF (N_MPI_PROCESSES>1) CALL EXCHANGE_HVAC_BC
   IF (MYID==0) THEN
      CALL COLLAPSE_HVAC_BC(T)
      CALL SET_INIT_HVAC
   ENDIF
ENDIF

! Make an initial dump of ambient values

IF (.NOT.RESTART) THEN
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL UPDATE_GLOBAL_OUTPUTS(T,DT,NM)
      CALL DUMP_MESH_OUTPUTS(T,DT,NM)
   ENDDO
   IF (MYID==0 .AND. VERBOSE) WRITE(LU_ERR,'(A)') ' Called DUMP_MESH_OUTPUTS'
ENDIF

! If there are zones and HVAC pass PSUM

IF (HVAC_SOLVE .AND. N_ZONE>0) CALL EXCHANGE_DIVERGENCE_INFO

! Make an initial dump of global output quantities

IF (.NOT.RESTART) THEN
   CALL EXCHANGE_GLOBAL_OUTPUTS
   CALL UPDATE_CONTROLS(T,0._EB,CTRL_STOP_STATUS,.TRUE.)
   CALL DUMP_GLOBAL_OUTPUTS
ENDIF

! Check for changes in VENT or OBSTruction control and device status at t=T_BEGIN

IF (.NOT.RESTART) THEN
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL OPEN_AND_CLOSE(T,NM)
   ENDDO
ENDIF

! Write out character strings to .smv file

CALL WRITE_STRINGS

! Check for evacuation initialization stop

IF (ANY(EVACUATION_ONLY)) THEN
   CALL STOP_CHECK(1)
   IF (.NOT.RESTART) ICYC = -EVAC_TIME_ITERATIONS
END IF

! Check for CC_IBM initialization stop

IF (CC_IBM) THEN
   IF (COMPUTE_CUTCELLS_ONLY) STOP_STATUS = SETUP_ONLY_STOP
   CALL STOP_CHECK(1)
ENDIF

! Sprinkler piping calculation

DO N=1,N_DEVC
   IF (DEVICE(N)%PROP_INDEX > 0 .AND.  DEVICE(N)%CURRENT_STATE) THEN
      IF (PROPERTY(DEVICE(N)%PROP_INDEX)%PART_INDEX > 0) DEVC_PIPE_OPERATING(DEVICE(N)%PIPE_INDEX) = &
         DEVC_PIPE_OPERATING(DEVICE(N)%PIPE_INDEX) + 1
   ENDIF
ENDDO

! Start the clock for time stepping

WALL_CLOCK_START_ITERATIONS = CURRENT_TIME()
T_USED = 0._EB
T_USED(1) = WALL_CLOCK_START_ITERATIONS

ALLOCATE (LU_GSTH(NMESHES))
ALLOCATE (FN_GSTH(NMESHES))  ! allocate sizes for time histories outside time loop

! This ends the initialization part of the program

INITIALIZATION_PHASE = .FALSE.

IF (MYID==0 .AND. VERBOSE) WRITE(LU_ERR,'(A)') ' Start the time-stepping loop'

!***********************************************************************************************************************************
!                                                   MAIN TIMESTEPPING LOOP
!***********************************************************************************************************************************

MAIN_LOOP: DO

   ICYC  = ICYC + 1   ! Time step iterations

   ! Do not print out general diagnostics into .out file every time step

   DIAGNOSTICS = .FALSE.
   EXCHANGE_EVACUATION = .FALSE.

   ! Check for program stops

   INQUIRE(FILE=FN_STOP,EXIST=EX)
   IF (EX .AND. ICYC>=STOP_AT_ITER) THEN
      IF (VERBOSE .AND. STOP_STATUS/=USER_STOP) WRITE(LU_ERR,'(A,I5)') ' STOP file detected, MPI Process =',MYID
      STOP_STATUS = USER_STOP
      DIAGNOSTICS = .TRUE.
   ENDIF

   ! Check to see if the time step can be increased

   IF (ALL(CHANGE_TIME_STEP_INDEX==1)) DT = MINVAL(DT_NEW,MASK=.NOT.EVACUATION_ONLY)

   ! Clip final time step

   IF ((T+DT+DT_END_FILL)>T_END) DT = MAX(T_END-T+TWO_EPSILON_EB,DT_END_MINIMUM)

   ! Determine when to dump out diagnostics to the .out file

   LO10 = INT(LOG10(REAL(MAX(1,ABS(ICYC)),EB)))
   IF (MOD(ICYC,10**LO10)==0 .OR. MOD(ICYC,100)==0 .OR. (T+DT)>=T_END) DIAGNOSTICS = .TRUE.

   ! If evacuation, set up special time iteration parameters

   IF (ANY(EVACUATION_ONLY)) CALL EVAC_MAIN_LOOP

   !================================================================================================================================
   !                                           Start of Predictor part of time step
   !================================================================================================================================

   PREDICTOR = .TRUE.
   CORRECTOR = .FALSE.

   ! Diagnostic timing calls and initialize energy budget array, Q_DOT

   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      Q_DOT(:,NM) = 0._EB
   ENDDO

   ! Begin the finite differencing of the PREDICTOR step

   COMPUTE_FINITE_DIFFERENCES_1: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE COMPUTE_FINITE_DIFFERENCES_1
      CALL INSERT_ALL_PARTICLES(T,NM)
      IF (.NOT.SOLID_PHASE_ONLY .AND. .NOT.FREEZE_VELOCITY) CALL COMPUTE_VISCOSITY(T,NM,APPLY_TO_ESTIMATED_VARIABLES=.FALSE.)
      CALL MASS_FINITE_DIFFERENCES(NM)
   ENDDO COMPUTE_FINITE_DIFFERENCES_1

   ! Estimate quantities at next time step, and decrease/increase time step if necessary based on CFL condition

   FIRST_PASS = .TRUE.

   CHANGE_TIME_STEP_LOOP: DO

      ! Predict species mass fractions at the next time step.

      COMPUTE_DENSITY_LOOP: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (EVACUATION_SKIP(NM)) CYCLE COMPUTE_DENSITY_LOOP
         CALL DENSITY(T,DT,NM)
         IF (LEVEL_SET_MODE>0) CALL LEVEL_SET_FIRESPREAD(T,DT,NM)
      ENDDO COMPUTE_DENSITY_LOOP

      IF (LEVEL_SET_MODE==2 .AND. CHECK_FREEZE_VELOCITY) CALL CHECK_FREEZE_VELOCITY_STATUS

      IF (CC_IBM) CALL CCREGION_DENSITY(T,DT)

      ! Exchange species mass fractions at interpolated boundaries.

      CALL MESH_EXCHANGE(1)
      IF (LEVEL_SET_MODE>0) CALL MESH_EXCHANGE(14)

      ! Gather local MESH average winds and compute global mean wind speed for forcing

      IF (FIRST_PASS .AND. ANY(MEAN_FORCING)) CALL GATHER_MEAN_WINDS

      ! Calculate convective and diffusive terms of the velocity equation.

      COMPUTE_DIVERGENCE_LOOP: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (EVACUATION_SKIP(NM)) CYCLE COMPUTE_DIVERGENCE_LOOP
         IF (.NOT.SOLID_PHASE_ONLY .AND. .NOT.FREEZE_VELOCITY) THEN
            MESHES(NM)%BAROCLINIC_TERMS_ATTACHED = .FALSE.
            CALL VISCOSITY_BC(NM,APPLY_TO_ESTIMATED_VARIABLES=.FALSE.)
            IF (.NOT.CYLINDRICAL) CALL VELOCITY_FLUX(T,DT,NM,APPLY_TO_ESTIMATED_VARIABLES=.FALSE.)
            IF (     CYLINDRICAL) CALL VELOCITY_FLUX_CYLINDRICAL(T,NM,APPLY_TO_ESTIMATED_VARIABLES=.FALSE.)
         ENDIF
         IF (FIRST_PASS .AND. HVAC_SOLVE) CALL HVAC_BC_IN(NM)
      ENDDO COMPUTE_DIVERGENCE_LOOP
      IF(CC_IBM .AND. .NOT.CC_FORCE_PRESSIT) CALL CCIBM_VELOCITY_FLUX

      ! HVAC solver

      IF (HVAC_SOLVE) THEN
         IF (FIRST_PASS .AND. N_MPI_PROCESSES>1) CALL EXCHANGE_HVAC_BC
         IF (MYID==0) CALL HVAC_CALC(T,DT,FIRST_PASS)
         IF (N_MPI_PROCESSES>1) CALL EXCHANGE_HVAC_SOLUTION
      ENDIF

      ! Boundary conditions for temperature, species, and density. Start divergence calculation.

      COMPUTE_WALL_BC_LOOP_A: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (EVACUATION_SKIP(NM)) CYCLE COMPUTE_WALL_BC_LOOP_A
         CALL UPDATE_PARTICLES(T,DT,NM)
         CALL WALL_BC(T,DT,NM)
         CALL PARTICLE_MOMENTUM_TRANSFER(NM)
         CALL DIVERGENCE_PART_1(T,DT,NM)
      ENDDO COMPUTE_WALL_BC_LOOP_A

      ! If there are pressure ZONEs, exchange integrated quantities mesh to mesh for use in the divergence calculation

      IF (N_ZONE>0) CALL EXCHANGE_DIVERGENCE_INFO

      ! Finish the divergence calculation

      FINISH_DIVERGENCE_LOOP: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (EVACUATION_SKIP(NM)) CYCLE FINISH_DIVERGENCE_LOOP
         CALL DIVERGENCE_PART_2(DT,NM)
      ENDDO FINISH_DIVERGENCE_LOOP

      ! Solve for the pressure at the current time step

      CALL PRESSURE_ITERATION_SCHEME
      CALL EVAC_PRESSURE_ITERATION_SCHEME

      ! Predict the velocity components at the next time step

      CHANGE_TIME_STEP_INDEX = 0
      DT_NEW = DT

      PREDICT_VELOCITY_LOOP: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (.NOT.ALL(EVACUATION_ONLY).AND.EVACUATION_ONLY(NM).AND.ICYC>0) CHANGE_TIME_STEP_INDEX(NM)=1
         IF (EVACUATION_SKIP(NM)) CYCLE PREDICT_VELOCITY_LOOP
         CALL VELOCITY_PREDICTOR(T+DT,DT,DT_NEW,NM)
      ENDDO PREDICT_VELOCITY_LOOP

      ! Check if there is a numerical instability after updating the velocity field. If there is, exit this loop, finish the time
      ! step, and stop the code.

      CALL STOP_CHECK(0)

      IF (STOP_STATUS==INSTABILITY_STOP) THEN
         DIAGNOSTICS = .TRUE.
         EXIT CHANGE_TIME_STEP_LOOP
      ENDIF

      ! Exchange CHANGE_TIME_STEP_INDEX to determine if the time step needs to be decreased (-1) or increased (1). If any mesh
      ! needs to decrease, or all need to increase, exchange the array of new time step values, DT_NEW.

      IF (N_MPI_PROCESSES>1) THEN
         TNOW = CURRENT_TIME()
         CALL MPI_ALLGATHERV(MPI_IN_PLACE,COUNTS(MYID),MPI_INTEGER,CHANGE_TIME_STEP_INDEX,COUNTS,DISPLS,&
                             MPI_INTEGER,MPI_COMM_WORLD,IERR)
         IF (ANY(CHANGE_TIME_STEP_INDEX==-1) .OR. ALL(CHANGE_TIME_STEP_INDEX==1)) &
            CALL MPI_ALLGATHERV(MPI_IN_PLACE,COUNTS(MYID),MPI_DOUBLE_PRECISION,DT_NEW,COUNTS,DISPLS, &
                                MPI_DOUBLE_PRECISION,MPI_COMM_WORLD,IERR)
         T_USED(11) = T_USED(11) + CURRENT_TIME() - TNOW
      ENDIF

      IF (ANY(CHANGE_TIME_STEP_INDEX==-1)) THEN  ! If the time step was reduced, CYCLE CHANGE_TIME_STEP_LOOP
         DT = MINVAL(DT_NEW,MASK=.NOT.EVACUATION_ONLY)
         FIRST_PASS = .FALSE.
      ELSE  ! exit the loop and if the time step is to be increased, this will occur at the next time step.
         EXIT CHANGE_TIME_STEP_LOOP
      ENDIF

   ENDDO CHANGE_TIME_STEP_LOOP

   ! If detailed CFL info needed

   IF (CFL_FILE) CALL WRITE_CFL_FILE

   ! Exchange velocity and pressures at interpolated boundaries

   CALL MESH_EXCHANGE(3)

   ! Flux average final velocity to cutfaces. Interpolate H to cut-cells from regular fluid cells.

   IF (CC_IBM) CALL CCIBM_END_STEP(T,DT,DIAGNOSTICS)

   ! Force normal components of velocity to match at interpolated boundaries

   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE
      CALL MATCH_VELOCITY(NM)
   ENDDO

   ! Apply tangential velocity boundary conditions

   VELOCITY_BC_LOOP: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE VELOCITY_BC_LOOP
      IF (SYNTHETIC_EDDY_METHOD) CALL SYNTHETIC_TURBULENCE(DT,T,NM)
      CALL VELOCITY_BC(T,NM,APPLY_TO_ESTIMATED_VARIABLES=.TRUE.)
   ENDDO VELOCITY_BC_LOOP

   ! Advance the time to start the CORRECTOR step

   T = T + DT

   !================================================================================================================================
   !                                           Start of Corrector part of time step
   !================================================================================================================================

   CORRECTOR = .TRUE.
   PREDICTOR = .FALSE.

   ! Finite differences for mass and momentum equations for the second half of the time step

   COMPUTE_FINITE_DIFFERENCES_2: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL OPEN_AND_CLOSE(T,NM)
      IF (EVACUATION_SKIP(NM)) CYCLE COMPUTE_FINITE_DIFFERENCES_2
      IF (.NOT.SOLID_PHASE_ONLY .AND. .NOT.FREEZE_VELOCITY) CALL COMPUTE_VISCOSITY(T,NM,APPLY_TO_ESTIMATED_VARIABLES=.TRUE.)
      CALL MASS_FINITE_DIFFERENCES(NM)
      CALL DENSITY(T,DT,NM)
      IF (LEVEL_SET_MODE>0) CALL LEVEL_SET_FIRESPREAD(T,DT,NM)
   ENDDO COMPUTE_FINITE_DIFFERENCES_2

   IF (LEVEL_SET_MODE==2 .AND. CHECK_FREEZE_VELOCITY) CALL CHECK_FREEZE_VELOCITY_STATUS

   IF (CC_IBM) CALL CCREGION_DENSITY(T,DT)
   IF (CHECK_MASS_CONSERVE) CALL CHECK_SPEC_TRANSPORT_CONSERVE(T,DT,DIAGNOSTICS)

   ! Exchange species mass fractions.

   CALL MESH_EXCHANGE(4)
   IF (LEVEL_SET_MODE>0) CALL MESH_EXCHANGE(14)

   ! Apply mass and species boundary conditions, update radiation, particles, and re-compute divergence

   COMPUTE_DIVERGENCE_2: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE COMPUTE_DIVERGENCE_2
      IF (.NOT.SOLID_PHASE_ONLY .AND. .NOT.FREEZE_VELOCITY) THEN
         MESHES(NM)%BAROCLINIC_TERMS_ATTACHED = .FALSE.
         CALL VISCOSITY_BC(NM,APPLY_TO_ESTIMATED_VARIABLES=.TRUE.)
         IF (.NOT.CYLINDRICAL) CALL VELOCITY_FLUX(T,DT,NM,APPLY_TO_ESTIMATED_VARIABLES=.TRUE.)
         IF (     CYLINDRICAL) CALL VELOCITY_FLUX_CYLINDRICAL(T,NM,APPLY_TO_ESTIMATED_VARIABLES=.TRUE.)
      ENDIF
      IF (AGGLOMERATION .AND. ANY(AGGLOMERATION_SMIX_INDEX>0)) CALL CALC_AGGLOMERATION(DT,NM)
      IF (N_REACTIONS > 0 .OR. INIT_HRRPUV) CALL COMBUSTION(T,DT,NM)
      IF (ANY(SPECIES_MIXTURE%CONDENSATION_SMIX_INDEX>0)) CALL CONDENSATION_EVAPORATION(DT,NM)
   ENDDO COMPUTE_DIVERGENCE_2
   IF(CC_IBM .AND. .NOT.CC_FORCE_PRESSIT) CALL CCIBM_VELOCITY_FLUX

   IF (HVAC_SOLVE) CALL HVAC_CALC(T,DT,.TRUE.)

   COMPUTE_WALL_BC_2A: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE COMPUTE_WALL_BC_2A
      IF (N_REACTIONS > 0) CALL COMBUSTION_BC(NM)
      CALL UPDATE_PARTICLES(T,DT,NM)
      CALL WALL_BC(T,DT,NM)
      CALL PARTICLE_MOMENTUM_TRANSFER(NM)
   ENDDO COMPUTE_WALL_BC_2A

   DO ITER=1,RADIATION_ITERATIONS
      DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (EVACUATION_SKIP(NM)) CYCLE
         CALL COMPUTE_RADIATION(T,NM,ITER)
         IF (CC_IBM) CALL CCCOMPUTE_RADIATION(T,NM,ITER)
      ENDDO
      IF (RADIATION_ITERATIONS>1) THEN  ! Only do an MPI exchange of radiation intensity if multiple iterations are requested.
         DO ANG_INC_COUNTER=1,ANGLE_INCREMENT
            CALL MESH_EXCHANGE(2)
            IF (ICYC>1) EXIT
         ENDDO
      ENDIF
   ENDDO

   ! Start the computation of the divergence term.

   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE
      CALL DIVERGENCE_PART_1(T,DT,NM)
   ENDDO

   ! In most LES fire cases, a correction to the source term in the radiative transport equation is needed.

   IF (RTE_SOURCE_CORRECTION) CALL CALCULATE_RTE_SOURCE_CORRECTION_FACTOR

   ! Exchange global pressure zone information

   IF (N_ZONE>0) CALL EXCHANGE_DIVERGENCE_INFO

   ! Finish computing the divergence

   FINISH_DIVERGENCE_LOOP_2: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE FINISH_DIVERGENCE_LOOP_2
      CALL DIVERGENCE_PART_2(DT,NM)
   ENDDO FINISH_DIVERGENCE_LOOP_2

   ! Solve the pressure equation.

   CALL PRESSURE_ITERATION_SCHEME
   CALL EVAC_PRESSURE_ITERATION_SCHEME

   ! Set up the last big exchange of info.

   CALL EVAC_MESH_EXCHANGE(T_EVAC,T_EVAC_SAVE,I_EVAC,ICYC,EXCHANGE_EVACUATION,0)

   ! Update the  velocity.

   CORRECT_VELOCITY_LOOP: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE CORRECT_VELOCITY_LOOP
      CALL VELOCITY_CORRECTOR(T,DT,NM)
      IF (DIAGNOSTICS .AND. .NOT.EVACUATION_ONLY(NM)) CALL CHECK_DIVERGENCE(NM)
   ENDDO CORRECT_VELOCITY_LOOP

   ! Exchange the number of particles sent from mesh to mesh

   CALL MESH_EXCHANGE(7)

   ! Exchange velocity, pressure, particles at interpolated boundaries

   CALL POST_RECEIVES(6)
   CALL MESH_EXCHANGE(6)

   ! Exchange radiation intensity at interpolated boundaries if only one iteration of the solver is requested.

   IF (RADIATION_ITERATIONS==1) THEN
      DO ANG_INC_COUNTER=1,ANGLE_INCREMENT
         CALL MESH_EXCHANGE(2)
         IF (ICYC>1) EXIT
      ENDDO
   ENDIF

   ! Flux average final velocity to cutfaces. Interpolate H to cut-cells from regular fluid cells.

   IF (CC_IBM) CALL CCIBM_END_STEP(T,DT,DIAGNOSTICS)

   ! Force normal components of velocity to match at interpolated boundaries

   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE
      CALL MATCH_VELOCITY(NM)
   ENDDO

   ! Apply velocity boundary conditions, and update values of HRR, DEVC, etc.

   VELOCITY_BC_LOOP_2: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE VELOCITY_BC_LOOP_2
      CALL VELOCITY_BC(T,NM,APPLY_TO_ESTIMATED_VARIABLES=.FALSE.)
      CALL UPDATE_GLOBAL_OUTPUTS(T,DT,NM)
   ENDDO VELOCITY_BC_LOOP_2

   ! Apply GENISTELA analysis for each mesh when radiation has been updated (radiation counter part of mesh info)
   
   ALLOCATE (LU_GSTA(NMESHES))
   ALLOCATE (FN_GSTA(NMESHES)) !* logical unit and name tied to number of meshes 
   
   EVAL_TMP_STEEL: DO NM=1,NMESHES
   IF (EVACUATION_SKIP(NM)) CYCLE  EVAL_TMP_STEEL  ! do not check for GENISTELA in evacuation model
   ! not checking the first time-step(ICYC==1)
   IF (MOD(MESHES(NM)%RAD_CALL_COUNTER,TIME_STEP_INCREMENT)==0 .AND. MOD(MESHES(NM)%RAD_CALL_COUNTER,ANGLE_INCREMENT)==0) THEN
   LU_GSTA(NM) = GET_FILE_NUMBER()  ! find available logical unit for writing output
   WRITE(FN_GSTA(NM),'(A,A,I3.3,A)') TRIM(CHID),'_',NM,'_gsta.csv'  ! write an output file for each mesh 
   OPEN(LU_GSTA(NM),FILE=FN_GSTA(NM),FORM='FORMATTED',STATUS='REPLACE')
   WRITE(CSVHFMT,'(A,I5.1,A)') "(",7,"(A,','),A)" ! use this to set style for N character-string headings
   WRITE(LU_GSTA(NM),CSVHFMT) 'm','m','m','K','K','K','s'
   WRITE(LU_GSTA(NM),CSVHFMT) 'I','J','K','STEEL TEMP','PROT1 TEMP','PROT2 TEMP','TIME'  

   
   IF (TIMEHIST) THEN
   OPEN(LU_GSTH(NM),FILE=FN_GSTH(NM),FORM='FORMATTED',STATUS='OLD')
   CALL APPEND_FILE(LU_GSTH(NM),2,T_BEGIN+(T-T_BEGIN)*TIME_SHRINK_FACTOR)
   ELSE
   LU_GSTH(NM) = GET_FILE_NUMBER()
   WRITE(FN_GSTH(NM),'(A,A,I3.3,A)') TRIM(CHID),'_',NM,'_gsth.csv'
   OPEN(LU_GSTH(NM),FILE=FN_GSTH,FORM='FORMATTED',STATUS='REPLACE')
   WRITE(CSVHFMT,'(A,I5.1,A)') "(",46,"(A,','),A)" ! use this to set style for N character-string headings
   WRITE(LU_GSTH(NM),CSVHFMT) 's','s','K','K','K','m','m','m',&
   'K','m/s','m/s','m/s','kg/m3','J/kgK','W/m2','W/m2','m/s','N/m2s','','','','W/m2K',&
   '','W/mK','J/kgK','kg/m3','','K','J/kgK','','','','','',&
   '','W/mK','J/kgK','kg/m3','','K','J/kgK','','','','',''  
   WRITE(LU_GSTH(NM),CSVHFMT) 'TIME','TIMESTEP','STEEL TEMP','PROT1 TEMP','PROT2 TEMP','IPOS','JPOS','KPOS',&
   'GAS TMP','U','V','W','RHO_GAS','SHC_GAS','RADSUM','Q_RAD','VEL_MEAN','VISC_DYN','RE_NO','GR_NO','NU_NO','HTC_EFF',&
   'N_ITR','K_INT','SHC_INT','RHO_INT','WF_INT','TMP_SURF_INT','SHC_STEEL_INT','RK1_D','RK1_N','RK1_TRN','RK1F','RK1',&
   'N_ITR','K_P','SHC_P','RHO_P','WF','TMP_SURF','SHC_STEEL','RK2_D','RK2_N','RK2_TRN','RK2F','RK2'
   
   TIMEHIST = .TRUE.
   
   ENDIF
   
   CALL GENISTELA(T,DT,NM)  ! call within loop, as this depends on mesh identifier NM
   CLOSE(LU_GSTA(NM))  ! close output file so that next mesh or step can run
   CLOSE(LU_GSTH(NM))
   END IF
   ENDDO EVAL_TMP_STEEL
   
   DEALLOCATE (LU_GSTA)
   DEALLOCATE (FN_GSTA)  !* expected to free memory by deallocating

   
   ! Share device, HRR, mass data among all processes

   CALL EXCHANGE_GLOBAL_OUTPUTS

   ! Check for dumping end of timestep outputs

   CALL UPDATE_CONTROLS(T,DT,CTRL_STOP_STATUS,.FALSE.)
   IF (CTRL_STOP_STATUS) STOP_STATUS = CTRL_STOP

   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_SKIP(NM)) CYCLE
      CALL DUMP_MESH_OUTPUTS(T,DT,NM)
   ENDDO

   ! Dump outputs such as HRR, DEVC, etc.

   CALL DUMP_GLOBAL_OUTPUTS

   ! Exchange EVAC information among meshes

   CALL EVAC_EXCHANGE

   ! Dump out diagnostics

   IF (DIAGNOSTICS) THEN
      CALL WRITE_STRINGS
      IF (.NOT.SUPPRESS_DIAGNOSTICS .AND. N_MPI_PROCESSES>1) CALL EXCHANGE_DIAGNOSTICS
      IF (MYID==0) CALL WRITE_DIAGNOSTICS(T,DT)
   ENDIF

   ! Flush output file buffers

   IF (T>=FLUSH_CLOCK .AND. FLUSH_FILE_BUFFERS) THEN
      IF (MYID==0) CALL FLUSH_GLOBAL_BUFFERS
      IF (MYID==MAX(0,EVAC_PROCESS)) CALL FLUSH_EVACUATION_BUFFERS
      DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (EVACUATION_ONLY(NM)) CYCLE
         CALL FLUSH_LOCAL_BUFFERS(NM)
      ENDDO
      FLUSH_CLOCK = FLUSH_CLOCK + DT_FLUSH
   ENDIF

   ! Dump a restart file if necessary

   CALL MPI_ALLGATHERV(MPI_IN_PLACE,COUNTS(MYID),MPI_LOGICAL,RADIATION_COMPLETED,COUNTS,DISPLS,MPI_LOGICAL,MPI_COMM_WORLD,IERR)
   IF ( (T>=RESTART_CLOCK .OR. STOP_STATUS==USER_STOP) .AND. (T>=T_END .OR. ALL(RADIATION_COMPLETED)) ) THEN
      DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (EVACUATION_SKIP(NM)) CYCLE
         CALL DUMP_RESTART(T,DT,NM)
      ENDDO
      RESTART_CLOCK = RESTART_CLOCK + DT_RESTART
   ENDIF

   ! Check for abnormal run stop

   CALL STOP_CHECK(1)  ! The argument 1 means that FDS will end unless there is logic associated with the STOP_STATUS

   ! Stop the run normally

   IF (T>=T_END .AND. ICYC>0) EXIT MAIN_LOOP

ENDDO MAIN_LOOP

!***********************************************************************************************************************************
!                                                     END OF TIME STEPPING LOOP
!***********************************************************************************************************************************

DEALLOCATE (LU_GSTH)
DEALLOCATE (FN_GSTH)  ! deallocate these to avoid memory issues

! Deallocate GLMAT_SOLVER_H variables if needed:

IF (PRES_METHOD == 'GLMAT') CALL FINISH_GLMAT_SOLVER_H

! Finish unstructured geometry

IF (CC_IBM) CALL FINISH_CCIBM

! Stop the calculation

CALL END_FDS

! This is the end of program. Supporting routines are listed below.

CONTAINS
!/////////////////////////////////////////////////////////////////////////////////////////////////////
! Include GeniSTELA subroutines as part of main program, unless a separate module is more appropriate


SUBROUTINE GENISTELA(T,DT, NM)
!! MAIN BODY OF CALCULATION PROCEDURE TO FIND STEEL AND PROTECTIVE LAYER TEMPERATURES FOR GENERIC MEMBER SUBJECT TO NATURAL FIRE

!---------------------------------------INITIALISATION OF VALUES------------------------------------------------------------------!
USE RADCONS, ONLY : TIME_STEP_INCREMENT ! include TSI for GENISTELA activation
USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_HEAT

! COUNTERS AND FLAGS
INTEGER, INTENT(IN) :: NM  ! read what mesh is being analysed
REAL(EB), INTENT(IN) :: T,DT  ! ensure that timestep is being read
REAL(EB) :: SIMTIME  ! format simulation time for output
TYPE (MESH_TYPE), POINTER :: M  ! re-define pointer
INTEGER ::  I_GS, J_GS, K_GS
INTEGER, POINTER :: NX, NY, NZ  ! positional counters and number of cells respectively

LOGICAL :: VERTICAL, SOLIDSECTION, CORRECTION, CORREND, CORRJUNC, AXIAL_LT

! CONTROL VARIABLES FOR NEWTON-RAPHSON AND RUNGE-KUTTA
REAL(EB) :: DT_GS
INTEGER, PARAMETER :: ITER_MAX = 10
REAL(EB), PARAMETER :: NRTOL=0.001_EB
REAL(EB) :: DELTA_TMP, F_TMP, FPRIME_TMP, RK_1ST, RK_2ND, RK_1ST_AX, RK_2ND_AX,RK_1ST_DENOM,RK_1ST_DENOM1,RK_1ST_DENOM2,DTMP_LIM,&
RK_1ST_NET1,RK_1ST_NET2,RK_1ST_NET,RK_1ST_TRNS1,RK_1ST_TRNS2,RK_1ST_TRNS,RK_1STF,RK_1STF_AX,PER_TMP_AX,RK_2ND_DENOM,RK_2ND_DENOM1,&
RK_2ND_DENOM2,RK_2ND_NET1,RK_2ND_NET2,RK_2ND_NET,RK_2ND_TRNS1,RK_2ND_TRNS2,RK_2ND_TRNS,RK_2ND_AX_NET,RK_2NDF,RK_2NDF_AX
INTEGER :: NR_ITER, IRNK


! TEMPERATURE VARIABLES (including outputs)
REAL(EB) :: TMP_MBR0, TMP_SURF1, TMP_SURF2,  TMP_STEEL, TMP_STEEL_OLD,TMP_STEEL_AX, TMP_INVRAD, TMP_INVRAD_U, TMP_INVRAD_L, &
TMP_INSU, TMP_STEEL_MID, TMP_UPLIM, TMP_S_END, TMP_S_JUNC,TMP_GAS1, TMP_GAS2,TMP_INT_SURF1,TMP_INT_SURF2,TMP_GAS_UP,TMP_GAS_LOW

REAL(EB), ALLOCATABLE, DIMENSION(:,:,:) :: STEEL_TMP, PRT1_TMP, PRT2_TMP
REAL(EB), DIMENSION(2,ITER_MAX) :: TMP_SURF
REAL(EB), DIMENSION(2,ITER_MAX) :: TMP_INT_SURF

! GEOMETRY PARAMETERS
REAL(EB), PARAMETER :: L_MBR=2.95_EB, THK_FL=0.0142_EB, THK_WEB=0.0086_EB, WD_FL=0.254_EB, WD_WEB=0.254_EB
!  WD_MBR, H_MBR would be included here if they were used 

! GAS VARIABLES
REAL(EB) :: RADSUM, SHC_GAS ! allows potential matches for these to be tested from same label
! TMP, U, V, W, RHO can be called as they are from the mesh
! REAL(EB) :: EPS_XP, EPS_YP, EPS_ZP, ETA_XP, ETA_YP, ETA_ZP, PSI_XP, PSI_YP, PSI_ZP ! cell face projections for non-orthogonal

! PROPERTIES FOR ENERGY BALANCE EQUATIONS
! Values prescribed, until capability to read from ASCII file developed
REAL(EB) :: HTC_EFF
REAL(EB) :: A_S, Q_RAD, Q_RAD1, Q_RAD2
REAL(EB), PARAMETER :: EMSV_MBR1=0.8_EB, EMSV_MBR2=0.8_EB, EMSV_UPP=1._EB, EMSV_LOW=1._EB, EMSV_FIRE=1._EB
REAL(EB) :: K_PRT1, K_PRT2, K_INT_PRT1, K_INT_PRT2
REAL(EB), PARAMETER :: K_STEEL=45.811_EB ! W/K/m
REAL(EB), PARAMETER :: THK_PRT1=0.0254_EB, THK_PRT2=0.0254_EB
REAL(EB) :: THK_STEEL
REAL(EB) :: WF_PRT1, WF_PRT2, WF_INT_PRT1, WF_INT_PRT2
REAL(EB) :: THM_PEN_DEPTH1, THM_PEN_DEPTH2
REAL(EB), PARAMETER :: RHO_STEEL=7850._EB
REAL(EB) :: RHO_PRT1=680._EB, RHO_PRT2=680._EB, RHO_PRT1_DRY=680._EB, RHO_PRT2_DRY=680._EB, &
RHO_INT_PRT1=680._EB, RHO_INT_PRT2=680._EB
REAL(EB) :: SHC_STEEL, SHC_STEEL_INT
REAL(EB) :: SHC_PRT1, SHC_PRT2, SHC_INT_PRT1, SHC_INT_PRT2

! PROPERTIES FOR CORRECTION TERMS
REAL(EB) :: THM_EXP=0.005_EB, PR_NO=0.72_EB, C_SUL1=1.458E-6_EB, C_SUL2=110.4_EB,  VEL_MEAN, VISC_DYN, VISC_KIN, RE_NO,&
GR_NO, RA_NO, NU_NO,CONV_CHK, R_INTU=1._EB, AX_UP,AX_LOW,AX_INT_UP,AX_INT_LOW, TMP_MOIST_INIT=373.15, TMP_MOIST_UP=413.15, &
ZZ_GET(1:N_TRACKED_SPECIES), CHI_JUNC, Q_JUNC, HFG_MAX, HFG, Q_RAD_AX, Q_CONV_AX, Q_TOT_AX, DELT_I,&
THM_PEN_DEPTH_UP,THM_PEN_DEPTH_LOW,CHI_AX,ST_UP1,ST_UP1_DENOM,ST_UP1_NUM,ST_UP2,ST_UP2_DENOM,ST_UP2_NUM,ST_LOW1,ST_LOW1_DENOM,&
ST_LOW1_NUM,ST_LOW2,ST_LOW2_DENOM,ST_LOW2_NUM,LT_UP,LT_LOW

INTEGER :: I_AX, I_AX_MAX
! XC, YC, ZC available from mesh module with same labels

REAL(EB) :: CHAR_L_STEEL = WD_FL ! relate characteristic length to given flange width
REAL(EB) :: IPOS, JPOS, KPOS  ! express I,J,K as dimensions corresponding to end face coordinates


! POINTERS
CHARACTER(80) :: CSVDFMT  ! replicate style of setting CSV output from dump module
M => MESHES(NM)  ! use M to point to mesh variables

! number of cells should be obtained from user input, so that all (gas-phase) cells covered
NX => M%IBAR
NY => M%JBAR
NZ => M%KBAR

! COMPARATIVE VALUES
THK_STEEL = MIN(THK_WEB,THK_FL) ! set as poorer case, until sophisticated enough to identify geometry
DT_GS = TIME_STEP_INCREMENT*ANGLE_INCREMENT*DT ! use increments from radiation as a factor to adjust time-step size

! allocate the size for temperature arrays based on number of cells
ALLOCATE (STEEL_TMP(1:NX,1:NY,1:NZ))
ALLOCATE (PRT1_TMP(1:NX,1:NY,1:NZ))
ALLOCATE (PRT2_TMP(1:NX,1:NY,1:NZ))


TMP_MBR0 = TMPA ! ambient surface temperature; unless known better, member starts at ambient temperature (Kelvin)


! initialises temperatures to ambient at first call (i.e. temperature is 0)
DO K_GS=1,NZ
DO J_GS=1,NY
DO I_GS=1,NX

IF (STEEL_TMP(I_GS,J_GS,K_GS) == 0) THEN
STEEL_TMP(I_GS,J_GS,K_GS) = TMP_MBR0
PRT1_TMP(I_GS,J_GS,K_GS) = TMP_MBR0
PRT2_TMP(I_GS,J_GS,K_GS) = TMP_MBR0
ENDIF

ENDDO
ENDDO
ENDDO

! intialises temperatures to ambient (performed outside above loop, as these are independent of position)
TMP_INT_SURF(1,0) = TMP_MBR0
TMP_INT_SURF(2,0) = TMP_MBR0

!////////////// ////////////////////START POSITIONAL COUNTERS OF MAIN LOOP ///////////////////////////////////////////////////////!
DO K_GS=1,NZ
DO J_GS=1,NY
DO I_GS=1,NX

!  COMPLETE THE CALCULATION PROCESS IF THE CELL IS NOT PART OF A SOLID OBSTRUCTION
IF (.NOT. M%SOLID(M%CELL_INDEX(I_GS,J_GS,K_GS))) THEN

! may not be necessary to find sum of radiant intensities, but it is left here as an option 
RADSUM = M%UII(I_GS,J_GS,K_GS) ! 'sum of radiation' is sum of radiation intensities at point

! find specific heat dependent on temperature and mixture of species in gas (products)
ZZ_GET(1:N_TRACKED_SPECIES) = M%ZZ(I_GS,J_GS,K_GS,1:N_TRACKED_SPECIES)
CALL GET_SPECIFIC_HEAT(ZZ_GET,SHC_GAS, M%TMP(I_GS,J_GS,K_GS))
! SHC_GAS = CP_GAMMA ! alternative value independent of temperature

! SURFACE AREA, RADIANT HEAT FLUX, LOCAL TEMPERATURES
A_S = 2*(M%DX(I_GS)*M%DZ(K_GS) +M%DY(J_GS) *M%DZ(K_GS) +M%DX(I_GS)*M%DY(J_GS)) ! allows for non-uniform meshing
! do not appear to need cell surface area, since UII already in units of W/m2

! surface area formulae using projections enclosed here
! A_S = 2*( SQRT(EPS_XP(I_GS,J_GS,K_GS)**2+(EPS_YP(I_GS,J_GS,K_GS)**2)+(EPS_ZP(I_GS,J_GS,K_GS)**2)) &
! SQRT(ETA_XP(I_GS,J_GS,K_GS)**2+(ETA_YP(I_GS,J_GS,K_GS)**2)+(ETA_ZP(I_GS,J_GS,K_GS)**2)) &
! SQRT(PSI_XP(I_GS,J_GS,K_GS)**2+(PSI_YP(I_GS,J_GS,K_GS)**2)+(PSI_ZP(I_GS,J_GS,K_GS)**2)) )

IF (A_S > 0._EB) THEN
Q_RAD = MAX(M%QR(I_GS,J_GS,K_GS), SIGMA*EMSV_FIRE*TMP_MBR0**4)
ELSE
Q_RAD = SIGMA*EMSV_FIRE*TMP_MBR0**4
ENDIF

Q_RAD1 = Q_RAD
Q_RAD2 = Q_RAD ! defined separately so that different values possible

! more convenient way to store temperature values for later use
TMP_STEEL = STEEL_TMP(I_GS, J_GS, K_GS)
TMP_GAS1 = M%TMP(I_GS, J_GS, K_GS)
TMP_GAS2 = M%TMP(I_GS, J_GS, K_GS)
! more temperature definitions
TMP_STEEL_MID = STEEL_TMP(I_GS, J_GS, K_GS)
TMP_UPLIM = TMPM + 1550._EB ! approximately above typical melting point of steel (converts degC to K)

! CONVECTIVE HEAT TRANSFER COEFFICIENT (consistent with Section 3.2.2 of GeniSTELA PhD)
VEL_MEAN = SQRT(M%U(I_GS,J_GS,K_GS)**2 + M%V(I_GS,J_GS,K_GS)**2 + M%W(I_GS,J_GS,K_GS)**2)

IF (M%TMP(I_GS,J_GS,K_GS) .GE. 0) THEN  ! Sutherland's Law
VISC_DYN = C_SUL1*M%TMP(I_GS,J_GS,K_GS)**1.5/(M%TMP(I_GS,J_GS,K_GS)+C_SUL2)
ELSE
VISC_DYN = 1E10_EB
ENDIF

VISC_KIN = VISC_DYN/M%RHO(I_GS,J_GS,K_GS)

! Reynolds Number 
IF (M%RHO(I_GS,J_GS,K_GS) .GE. 0) THEN
IF (VISC_DYN > 0) THEN 
RE_NO = VEL_MEAN*CHAR_L_STEEL/VISC_KIN
ELSE
RE_NO = 1E10_EB
ENDIF
ELSE
RE_NO = 0
ENDIF

! Grashof Number
IF (VISC_DYN > 0 .AND. M%RHO(I_GS,J_GS,K_GS)  > 0) THEN
GR_NO = ABS((STEEL_TMP(I_GS,J_GS,K_GS)-M%TMP(I_GS,J_GS,K_GS))*GRAV*THM_EXP*CHAR_L_STEEL**3/(VISC_KIN**2))
ELSE
GR_NO = 0
ENDIF

! Rayleigh Number 
RA_NO = GR_NO*PR_NO

CONV_CHK = GR_NO/(RE_NO)**2

! at present, must explicitly state whether member is vertical or not (i.e. horizontal) and solid section or hollow
! VERTICAL = .TRUE.
VERTICAL = .FALSE.
SOLIDSECTION = .TRUE.
! SOLIDSECTION = .FALSE.

! See Table 3.2 of GeniSTELA PhD for explanation of free/forced convection and laminar/turbulent flow for Nusselt Number 
IF (SOLIDSECTION) THEN

IF (CONV_CHK > 1._EB) THEN ! free convection

IF (VERTICAL) THEN 
NU_NO =  0.638*GR_NO**0.25*PR_NO**0.5*(0.861_EB+PR_NO)**0.25	
ELSE
NU_NO = ((0.825_EB+0.387_EB*RA_NO**(1._EB/6._EB))/((1._EB+(0.492_EB/PR_NO)**(9._EB/16._EB))**(4._EB/9._EB)))**2
ENDIF 

ELSE ! forced convection
! should be laminar/turbulent, but this is reflective of original code
IF (VERTICAL) THEN 
NU_NO = 0.664*RE_NO**0.5*PR_NO**(1._EB/3._EB)
ELSE
NU_NO = 0.228*RE_NO**0.731*PR_NO**(1._EB/3._EB)
ENDIF
ENDIF
ENDIF

HTC_EFF = VISC_DYN*SHC_GAS*NU_NO/(CHAR_L_STEEL*PR_NO) ! use effective value for all instances of conv. h.t.c.


!//////////////////////// ///////// INTERMEDIATE TEMPERATURES (EULER STEP) ///////////////////////////////////////////////////////!

!---------------------------INTERMEDIATE (PROTECTIVE LAYER) TEMPERATURES NEWTON-RAPHSON-------------------------------------------!
! Find the intermediate temperature information first, so that steel and protection can be corrected within time-step

TMP_INT_SURF(1,0) = PRT1_TMP(I_GS,J_GS,K_GS)
TMP_INT_SURF(2,0) = PRT2_TMP(I_GS,J_GS,K_GS) ! set initial estimate to previous protection temperature

! NEWTON RAPHSON FOR INTERMEDIATE (PROTECTIVE LAYER) TEMPERATURES
NEWTON_RAPHSON: DO NR_ITER = 1,ITER_MAX
IRNK =NR_ITER ! save iteration rank for later reference
TMP_STEEL_OLD = TMP_STEEL ! use steel temperature from previous time-step

TMP_INT_SURF(1,NR_ITER) = TMP_INT_SURF(1,NR_ITER-1) 
TMP_INT_SURF(2,NR_ITER) = TMP_INT_SURF(2,NR_ITER-1)  ! update temperatures 

IF (THK_PRT1 > 0._EB) THEN ! find weight factor given that protective layer exists (*switched order of if statements from original code)
IF (R_INTU > 1.01_EB) THEN ! check if intumescent or moisture effects to be applied
CALL INTUMESCE (SHC_INT_PRT1, K_INT_PRT1, RHO_INT_PRT1, RHO_PRT1_DRY, R_INTU, (TMP_INT_SURF(1,NR_ITER)+TMP_STEEL_OLD)/2)
ELSE
CALL MOISTURE (K_INT_PRT1, SHC_INT_PRT1, (TMP_INT_SURF(1,NR_ITER)+TMP_STEEL_OLD)/2, TMP_MOIST_INIT, TMP_MOIST_UP)
ENDIF

THM_PEN_DEPTH1 = 2._EB*SQRT(K_INT_PRT1*(CURRENT_TIME()+DT_GS)/(SHC_INT_PRT1*RHO_INT_PRT1))
WF_INT_PRT1 = MIN ((THM_PEN_DEPTH1/THK_PRT1),1._EB)

ELSE
WF_INT_PRT1 = 1._EB
ENDIF
RHO_INT_PRT1 = RHO_PRT1_DRY  ! set density to non-intumescing, non-moisture value

IF (THK_PRT2 > 0._EB) THEN ! find weight factor given that protective layer exists (*switched order of if statements from original)
IF (R_INTU > 1.01_EB) THEN ! check if intumescent or moisture effects to be applied
CALL INTUMESCE (SHC_INT_PRT2, K_INT_PRT2, RHO_INT_PRT2, RHO_PRT2_DRY, R_INTU, (TMP_INT_SURF(2,NR_ITER)+TMP_STEEL_OLD)/2)
ELSE 
CALL MOISTURE (K_INT_PRT2, SHC_INT_PRT2, (TMP_INT_SURF(2,NR_ITER)+TMP_STEEL_OLD)/2, TMP_MOIST_INIT, TMP_MOIST_UP)
ENDIF

THM_PEN_DEPTH2 = 2._EB*SQRT(K_INT_PRT2*(CURRENT_TIME()+DT_GS)/(SHC_INT_PRT2*RHO_INT_PRT2)) 
WF_INT_PRT2 = MIN ((THM_PEN_DEPTH2/THK_PRT2),1._EB)

ELSE
WF_INT_PRT2 = 1._EB
ENDIF
RHO_INT_PRT2 = RHO_PRT2_DRY  ! set density to non-intumescing, non-moisture value

IF (THK_PRT1 > 0._EB) THEN
! find f(TMP), f'(TMP)
CALL BOUND_CONDN (F_TMP,TMP_INT_SURF(1,NR_ITER),HTC_EFF,TMP_GAS1,TMP_STEEL,Q_RAD1,EMSV_MBR1,SIGMA,K_INT_PRT1,THK_PRT1,WF_INT_PRT1)
CALL BOUND_CONDN_PRIME (FPRIME_TMP,TMP_INT_SURF(1,NR_ITER),HTC_EFF,SIGMA,EMSV_MBR1,K_INT_PRT1,WF_INT_PRT1,THK_PRT1)
DELTA_TMP = F_TMP / FPRIME_TMP
TMP_INT_SURF1= TMP_INT_SURF(1,NR_ITER) - DELTA_TMP
TMP_INT_SURF(1,NR_ITER) = MIN(TMP_UPLIM, MAX(TMP_INT_SURF1,TMP_MBR0))

ELSE
TMP_INT_SURF(1,NR_ITER) = TMP_STEEL
ENDIF

IF (THK_PRT2 > 0._EB) THEN
! find f(TMP), f'(TMP)
CALL BOUND_CONDN (F_TMP,TMP_INT_SURF(2,NR_ITER),HTC_EFF,TMP_GAS2,TMP_STEEL,Q_RAD2,EMSV_MBR2,SIGMA,K_INT_PRT2,THK_PRT2,WF_INT_PRT2)
CALL BOUND_CONDN_PRIME (FPRIME_TMP,TMP_INT_SURF(2,NR_ITER),HTC_EFF,SIGMA,EMSV_MBR2,K_INT_PRT2,WF_INT_PRT2,THK_PRT2) 
DELTA_TMP = F_TMP / FPRIME_TMP
TMP_INT_SURF2= TMP_INT_SURF(2,NR_ITER) - DELTA_TMP
TMP_INT_SURF(2,NR_ITER) = MIN(TMP_UPLIM, MAX(TMP_INT_SURF2,TMP_MBR0))

ELSE
TMP_INT_SURF(2,NR_ITER) = TMP_STEEL
ENDIF

! stop iterating if temperature values within 0.1%
IF ( ABS((TMP_INT_SURF(1,NR_ITER) - TMP_INT_SURF(1,NR_ITER-1))/TMP_INT_SURF(1,NR_ITER-1)) < NRTOL .AND. &
ABS((TMP_INT_SURF(2,NR_ITER) - TMP_INT_SURF(2,NR_ITER-1))/TMP_INT_SURF(2,NR_ITER-1)) < NRTOL ) EXIT  NEWTON_RAPHSON 
 
 
ENDDO NEWTON_RAPHSON


!------------------------------------------AXIAL CORRECTION-----------------------------------------------------------------------!
! Most of the axial correction terms are unaltered between the intermediate and corrected steps.
! Hence, the majority of the calculations are completed at this stage, so that it can be applied at the intermediate 

!* MANUALLY ACTIVATE (AXIAL) CORRECTION (until input file developed)
CORRECTION = .FALSE.

! Locate maximum heat flux gradient along axial direction
HFG_MAX = 0._EB
HFG = 0_EB

DO I_AX = I_GS,NX

Q_RAD_AX = MAX(M%QR(I_AX,J_GS,K_GS), SIGMA*EMSV_FIRE*TMP_MBR0**4)
Q_CONV_AX = HTC_EFF*M%TMP(I_AX,J_GS,K_GS)
Q_TOT_AX = MAX((EMSV_MBR1*Q_RAD_AX + Q_CONV_AX), (EMSV_MBR2*Q_RAD_AX + Q_CONV_AX))

DELT_I = ABS(M%XC(I_AX) - M%XC(I_GS))

HFG = Q_TOT_AX / DELT_I

IF (.NOT. M%SOLID(M%CELL_INDEX(I_AX,J_GS,K_GS))) THEN
IF (HFG > HFG_MAX) THEN
HFG_MAX = HFG
I_AX_MAX = I_AX
END IF
END IF

END DO

! Upper value of inverted radiation temperature, thermal penetration depth, gas temperature
TMP_INVRAD_U = MAX(TMPA,(M%QR(I_AX_MAX,J_GS,K_GS)/(SIGMA*EMSV_FIRE))**0.25)
THM_PEN_DEPTH_UP = ABS(M%XC(I_AX_MAX) - M%XC(I_GS))
TMP_GAS_UP = M%TMP(I_AX_MAX,J_GS,K_GS)

! Find gradient at current location
DO I_AX = I_GS,1,-1

Q_RAD_AX = MAX(M%QR(I_AX,J_GS,K_GS), SIGMA*EMSV_FIRE*TMP_MBR0**4)
Q_CONV_AX = HTC_EFF*M%TMP(I_AX,J_GS,K_GS)
Q_TOT_AX = MAX((EMSV_MBR1*Q_RAD_AX + Q_CONV_AX), (EMSV_MBR2*Q_RAD_AX + Q_CONV_AX))

DELT_I = ABS(M%XC(I_AX) - M%XC(I_GS))

HFG = Q_TOT_AX / DELT_I

IF (.NOT. M%SOLID(M%CELL_INDEX(I_AX,J_GS,K_GS))) THEN
IF (HFG > HFG_MAX) THEN
HFG_MAX = HFG
I_AX_MAX = I_AX
END IF
END IF

END DO

! Lower value of inverted radiation temperature, thermal penetration depth, gas temperature
TMP_INVRAD_L = MAX(TMPA,(M%QR(I_AX_MAX,J_GS,K_GS)/(SIGMA*EMSV_FIRE))**0.25)
THM_PEN_DEPTH_LOW = ABS(M%XC(I_AX_MAX) - M%XC(I_GS))
TMP_GAS_LOW = M%TMP(I_AX_MAX,J_GS,K_GS)

! Find axial length scale parameter and set whether it has long-term or short-term effects
AXIAL_LT = .FALSE.

CHI_AX = 0._EB
TMP_INVRAD = MAX(TMPA,(M%QR(I_GS,J_GS,K_GS)/(SIGMA*EMSV_FIRE))**0.25)

IF (TMP_INVRAD > TMPA) THEN
CHI_AX = (TMP_STEEL_MID - TMP_MBR0) / (TMP_INVRAD-TMPA)
END IF

IF (CHI_AX > 0.5) THEN
AXIAL_LT = .TRUE.
END IF

! SHORT-TERM CORRECTION PRE-CALCULATION
IF (CHI_AX > 0.01 .AND. CHI_AX .LE. 0.5) THEN
! Upper cell correction
ST_UP1_NUM = HTC_EFF*(TMP_GAS_UP - TMPA) + EMSV_UPP*SIGMA*TMP_INVRAD_U**4 - EMSV_MBR1*SIGMA*TMPA**4
ST_UP1_DENOM = HTC_EFF*(TMP_GAS1 - TMPA) + EMSV_MBR1*SIGMA*TMP_INVRAD**4 - EMSV_MBR1*SIGMA*TMPA**4

IF (ST_UP1_DENOM .LE. 0.001_EB .AND. ST_UP1_NUM .NE. 0) THEN
ST_UP1 = 0._EB
ELSE
ST_UP1 = ST_UP1_NUM/ST_UP1_DENOM - 1._EB
END IF

ST_UP2_NUM = HTC_EFF*(TMP_GAS_UP - TMPA) + EMSV_UPP*SIGMA*TMP_INVRAD_U**4 - EMSV_MBR2*SIGMA*TMPA**4
ST_UP2_DENOM = HTC_EFF*(TMP_GAS2 - TMPA) + EMSV_MBR2*SIGMA*TMP_INVRAD**4 - EMSV_MBR2*SIGMA*TMPA**4

IF (ST_UP2_DENOM .LE. 0.001_EB .AND. ST_UP2_NUM .NE. 0) THEN
ST_UP2 = 0._EB
ELSE
ST_UP2 = ST_UP2_NUM/ST_UP2_DENOM - 1._EB
END IF

! Lower cell correction
ST_LOW1_NUM = HTC_EFF*(TMP_GAS_LOW - TMPA) + EMSV_LOW*SIGMA*TMP_INVRAD_U**4 - EMSV_MBR1*SIGMA*TMPA**4
ST_LOW1_DENOM = HTC_EFF*(TMP_GAS1 - TMPA) + EMSV_MBR1*SIGMA*TMP_INVRAD**4 - EMSV_MBR1*SIGMA*TMPA**4

IF (ST_LOW1_DENOM .LE. 0.001_EB .AND. ST_LOW1_NUM .NE. 0) THEN
ST_LOW1 = 0._EB
ELSE
ST_LOW1 = -ST_LOW1_NUM/ST_LOW1_DENOM + 1._EB
END IF

ST_LOW2_NUM = HTC_EFF*(TMP_GAS_LOW - TMPA) + EMSV_LOW*SIGMA*TMP_INVRAD_U**4 - EMSV_MBR2*SIGMA*TMPA**4
ST_LOW2_DENOM = HTC_EFF*(TMP_GAS2 - TMPA) + EMSV_MBR2*SIGMA*TMP_INVRAD**4 - EMSV_MBR2*SIGMA*TMPA**4

IF (ST_LOW2_DENOM .LE. 0.001_EB .AND. ST_LOW2_NUM .NE. 0) THEN
ST_LOW2 = 0._EB
ELSE
ST_LOW2 = -ST_LOW2_NUM/ST_LOW2_DENOM + 1._EB
END IF

! LONG TERM CORRECTION PRE-CALCULATION
ELSE IF (CHI_AX > 0.5) THEN
LT_UP = TMP_INVRAD_U/TMP_INVRAD - 1._EB
LT_LOW = 1._EB - TMP_INVRAD_L/TMP_INVRAD

END IF

! INTERMEDIATE AXIAL CORRECTION VALUES
IF (CHI_AX > 0.01 .AND. CHI_AX .LE. 0.5) THEN

! Short term, upper cell
IF (THM_PEN_DEPTH_UP > 0_EB) THEN
AX_INT_UP = K_STEEL/THM_PEN_DEPTH_UP * (TMP_STEEL_MID - TMP_MBR0) * 0.5*(ST_UP1 + ST_UP2)
ELSE
AX_INT_UP = 0._EB
ENDIF

! Short term, lower cell
IF (THM_PEN_DEPTH_LOW > 0_EB) THEN
AX_INT_LOW = K_STEEL/THM_PEN_DEPTH_LOW * (TMP_STEEL_MID - TMP_MBR0) * 0.5*(ST_LOW1 + ST_LOW2)
ELSE
AX_INT_LOW = 0._EB
ENDIF

ELSE IF (CHI_AX > 0.5) THEN

! Long term, upper cell
IF (THM_PEN_DEPTH_UP > 0_EB) THEN
AX_INT_UP = K_STEEL/THM_PEN_DEPTH_UP * TMP_STEEL_MID * LT_UP
ELSE
AX_INT_UP = 0._EB
ENDIF

! Long term, lower cell
IF (THM_PEN_DEPTH_LOW > 0_EB) THEN
AX_INT_LOW = K_STEEL/THM_PEN_DEPTH_LOW * TMP_STEEL_MID * LT_LOW
ELSE
AX_INT_LOW = 0._EB
ENDIF

ELSE
AX_INT_UP = 0._EB
AX_INT_LOW = 0._EB
END IF


!------------------------------FIRST RUNGE-KUTTA COEFFICIENT (K1) AND INTERMEDIATE TEMPERATURES-----------------------------------!
! Break the components of K1 into manageable parts to avoid transcription errors
! Determine intermediate temperatures, which are exploited to find second RK coefficient (K2)

DTMP_LIM = -1000 ! temperature difference between time-steps needs stability limit

! Find temperature-dependent value of SHC (i.e. c_p_steel)
CALL CPSTEEL(SHC_STEEL, TMP_STEEL)
SHC_STEEL_INT = SHC_STEEL  ! save this intermediate value for display, without disturbing the rest of the code

! Corrections for denominator using protection properties
IF (WF_INT_PRT1 < 1._EB) THEN 
RK_1ST_DENOM1 = 0.5_EB*WF_INT_PRT1*THK_PRT1*RHO_INT_PRT1*SHC_INT_PRT1
ELSE
RK_1ST_DENOM1 = 0._EB
ENDIF

IF (WF_INT_PRT2 < 1._EB) THEN
RK_1ST_DENOM2 = 0.5_EB*WF_INT_PRT2*THK_PRT2*RHO_INT_PRT2*SHC_INT_PRT2
ELSE
RK_1ST_DENOM2 = 0._EB
ENDIF

RK_1ST_DENOM = THK_STEEL*RHO_STEEL*SHC_STEEL + RK_1ST_DENOM1 + RK_1ST_DENOM2

! net heat transfer terms for protection 1+2
CALL NET_RK (RK_1ST_NET1,HTC_EFF,TMP_GAS1,TMP_INT_SURF(1,IRNK),Q_RAD1,EMSV_MBR1,SIGMA)
CALL NET_RK (RK_1ST_NET2,HTC_EFF,TMP_GAS2,TMP_INT_SURF(2,IRNK),Q_RAD2,EMSV_MBR2,SIGMA)
RK_1ST_NET = (RK_1ST_NET1+RK_1ST_NET2)/ RK_1ST_DENOM  

IF ((THK_PRT1 + THK_PRT2) > 0) THEN  ! transient terms only apply if there is a protective layer
CALL TRANS_RK (RK_1ST_TRNS1, TMP_INT_SURF(1,IRNK),PRT1_TMP(I_GS,J_GS,K_GS),THK_PRT1,WF_INT_PRT1,RHO_INT_PRT1,SHC_INT_PRT1,DT_GS,DTMP_LIM)
CALL TRANS_RK (RK_1ST_TRNS2, TMP_INT_SURF(2,IRNK),PRT2_TMP(I_GS,J_GS,K_GS),THK_PRT2,WF_INT_PRT2,RHO_INT_PRT2,SHC_INT_PRT2,DT_GS,DTMP_LIM)

RK_1ST_TRNS= (RK_1ST_TRNS1 + RK_1ST_TRNS2)/RK_1ST_DENOM
ELSE
RK_1ST_TRNS = 0._EB
ENDIF

RK_1STF = RK_1ST_NET + MIN(MAX(RK_1ST_TRNS, -RK_1ST_NET), RK_1ST_NET)

! Find ratio of axial correction to uncorrected function; if correction is too big, do not include to avoid divergence 
PER_TMP_AX = ABS((AX_INT_UP - AX_INT_LOW)/RK_1ST_DENOM) / RK_1STF

IF (PER_TMP_AX > 0.5) CORRECTION = .FALSE.

IF (CORRECTION) RK_1STF_AX = RK_1ST_NET + MIN(MAX(RK_1ST_TRNS, -RK_1ST_NET), RK_1ST_NET) + (AX_INT_UP - AX_INT_LOW)/RK_1ST_DENOM

RK_1ST = DT_GS*RK_1STF

IF (CORRECTION) RK_1ST = DT_GS*RK_1STF_AX

TMP_STEEL = MIN (TMP_UPLIM, MAX(TMP_STEEL_OLD+RK_1ST, TMP_MBR0))

IF (CORRECTION) TMP_STEEL_AX = MIN (TMP_UPLIM, MAX(TMP_STEEL_OLD+RK_1ST_AX, TMP_MBR0))


!//////////////////////////////////////// FINAL TEMPERATURES AT TIME-STEP (EULER-CAUCHY STEP) ////////////////////////////////////!

! Update protection temperatures to intermediate values
TMP_SURF(1,0) = TMP_INT_SURF(1,IRNK)
TMP_SURF(2,0) = TMP_INT_SURF(2,IRNK)

!----------------------------FINAL (PROTECTIVE LAYER) TEMPERATURES NEWTON-RAPHSON-------------------------------------------------!
! Find the protection temperature, using the intermediate protection and steel temperature

! NEWTON RAPHSON FOR PROTECTIVE LAYER TEMPERATURES
NEWTON_RAPHSON_FIN: DO NR_ITER = 1,ITER_MAX
IRNK =NR_ITER ! save iteration rank for later reference
TMP_STEEL_MID = TMP_STEEL  ! update this steel temperature to intermediate value
TMP_STEEL_OLD = TMP_STEEL ! use steel temperature from intermediate time-step

TMP_SURF(1,NR_ITER) = TMP_SURF(1,NR_ITER-1) 
TMP_SURF(2,NR_ITER) = TMP_SURF(2,NR_ITER-1)  ! update temperatures 

IF (THK_PRT1 > 0._EB) THEN ! find weight factor given that protective layer exists (*switched order of if statements from original)
IF (R_INTU > 1.01_EB) THEN ! check if intumescent or moisture effects to be applied
CALL INTUMESCE (SHC_PRT1, K_PRT1, RHO_PRT1, RHO_PRT1_DRY, R_INTU, (TMP_SURF(1,NR_ITER)+TMP_STEEL_OLD)/2._EB)
ELSE 
CALL MOISTURE (K_PRT1, SHC_PRT1, (TMP_SURF(1,NR_ITER)+TMP_STEEL_OLD)/2._EB, TMP_MOIST_INIT, TMP_MOIST_UP)
ENDIF

THM_PEN_DEPTH1 = 2._EB*SQRT(K_PRT1*(CURRENT_TIME()+DT_GS)/(SHC_PRT1*RHO_PRT1))
WF_PRT1 = MIN ((THM_PEN_DEPTH1/THK_PRT1),1._EB)

ELSE
WF_PRT1 = 1._EB
ENDIF
RHO_PRT1 = RHO_PRT1_DRY  ! set density to non-intumescing, non-moisture value

IF (THK_PRT2 > 0._EB) THEN ! find weight factor given that protective layer exists (*switched order of if statements from original)
IF (R_INTU > 1.01_EB) THEN ! check if intumescent or moisture effects to be applied
CALL INTUMESCE (SHC_PRT2, K_PRT2, RHO_PRT2, RHO_PRT2_DRY, R_INTU, (TMP_SURF(2,NR_ITER)+TMP_STEEL_OLD)/2._EB)
ELSE 
CALL MOISTURE (K_PRT2, SHC_PRT2, (TMP_SURF(2,NR_ITER)+TMP_STEEL_OLD)/2._EB, TMP_MOIST_INIT, TMP_MOIST_UP)
ENDIF

THM_PEN_DEPTH2 = 2._EB*SQRT(K_PRT2*(CURRENT_TIME()+DT_GS)/(SHC_PRT2*RHO_PRT2))
WF_PRT2 = MIN ((THM_PEN_DEPTH2/THK_PRT2),1._EB)

ELSE
WF_PRT2 = 1._EB
ENDIF
RHO_PRT2 = RHO_PRT2_DRY  ! set density to non-intumescing, non-moisture value

IF (THK_PRT1 > 0._EB) THEN
CALL BOUND_CONDN (F_TMP,TMP_SURF(1,NR_ITER),HTC_EFF,TMP_GAS1,TMP_STEEL,Q_RAD1,EMSV_MBR1,SIGMA,K_PRT1,THK_PRT1,WF_PRT1)
CALL BOUND_CONDN_PRIME (FPRIME_TMP,TMP_SURF(1,NR_ITER),HTC_EFF,SIGMA,EMSV_MBR1,K_PRT1,WF_PRT1,THK_PRT1) ! find f(TMP), f'(TMP)
DELTA_TMP = F_TMP / FPRIME_TMP
TMP_SURF1= TMP_SURF(1,NR_ITER) - DELTA_TMP
TMP_SURF(1,NR_ITER) = MIN(TMP_UPLIM, MAX(TMP_SURF1,TMP_MBR0))

ELSE
TMP_SURF(1,NR_ITER) = TMP_STEEL
ENDIF

IF (THK_PRT2 > 0._EB) THEN
CALL BOUND_CONDN (F_TMP,TMP_SURF(2,NR_ITER),HTC_EFF,TMP_GAS2,TMP_STEEL,Q_RAD2,EMSV_MBR2,SIGMA,K_PRT2,THK_PRT2,WF_PRT2)
CALL BOUND_CONDN_PRIME (FPRIME_TMP,TMP_SURF(2,NR_ITER),HTC_EFF,SIGMA,EMSV_MBR2,K_PRT2,WF_PRT2,THK_PRT2) ! find f(TMP), f'(TMP)
DELTA_TMP = F_TMP / FPRIME_TMP
TMP_SURF2= TMP_SURF(2,NR_ITER) - DELTA_TMP
TMP_SURF(2,NR_ITER) = MIN(TMP_UPLIM, MAX(TMP_SURF2,TMP_MBR0))

ELSE
TMP_SURF(2,NR_ITER) = TMP_STEEL
ENDIF

! stop iterating if within 0.1%
IF ( ABS((TMP_SURF(1,NR_ITER)-TMP_SURF(1,NR_ITER-1))/TMP_SURF(1,NR_ITER-1)) < NRTOL  .AND. &
ABS((TMP_SURF(2,NR_ITER)-TMP_SURF(2,NR_ITER-1))/TMP_SURF(2,NR_ITER-1))< NRTOL ) EXIT NEWTON_RAPHSON_FIN  
 
 
ENDDO NEWTON_RAPHSON_FIN


!------------------------------------------AXIAL CORRECTION-----------------------------------------------------------------------!
!*MOST OF THE CORRECTION TERMS ARE THE SAME VALUE AS AT INTERMEDIATE STAGE

! Re-calculate axial length scale parameter
IF (TMP_INVRAD > TMPA) THEN
CHI_AX = (TMP_STEEL_AX - TMP_MBR0)/(TMP_INVRAD - TMPA)
ELSE
CHI_AX = 0._EB
END IF

! AXIAL CORRECTION VALUES
IF(THM_PEN_DEPTH_UP > 0 .AND. THM_PEN_DEPTH_LOW > 0) THEN
IF (.NOT. AXIAL_LT) THEN

IF (CHI_AX > 0.01 .AND. CHI_AX .LE. 0.5) THEN
AXIAL_LT = .FALSE.

! Short term, upper cell
AX_UP = K_STEEL/THM_PEN_DEPTH_UP * (TMP_STEEL_AX - TMP_MBR0) * 0.5*(ST_UP1 + ST_UP2)

! Short term, lower cell
AX_INT_LOW = K_STEEL/THM_PEN_DEPTH_LOW * (TMP_STEEL_AX - TMP_MBR0) * 0.5*(ST_LOW1 + ST_LOW2)


ELSE IF (CHI_AX > 0.5) THEN
AXIAL_LT = .TRUE.

! Long term, upper cell
AX_UP = K_STEEL/THM_PEN_DEPTH_UP * TMP_STEEL_AX * LT_UP

! Long term, lower cell
AX_LOW = K_STEEL/THM_PEN_DEPTH_LOW * TMP_STEEL_AX * LT_LOW

ELSE
AX_UP = 0._EB
AX_LOW = 0._EB
END IF

! for long-term correction only 
ELSE
AX_UP = K_STEEL/THM_PEN_DEPTH_UP * TMP_STEEL_AX * LT_UP
AX_LOW = K_STEEL/THM_PEN_DEPTH_LOW * TMP_STEEL_AX * LT_LOW
END IF

END IF


!----------------------------------------SECOND RUNGE-KUTTA COEFFICIENT (K2)---------------------------------------------!
! Break the components of K2 into manageable parts to avoid transcription errors
! Calculates temperature at end of time-step without additional corrections

! Find temperature-dependent value of SHC (i.e. c_p_steel) 
CALL CPSTEEL(SHC_STEEL, TMP_STEEL)

! Corrections for denominator using protection properties
IF (WF_PRT1 < 1._EB) THEN 
RK_2ND_DENOM1 = 0.5_EB*WF_PRT1*THK_PRT1*RHO_PRT1*SHC_PRT1
ELSE
RK_2ND_DENOM1 = 0._EB
ENDIF

IF (WF_PRT2 < 1._EB) THEN
RK_2ND_DENOM2 = 0.5_EB*WF_PRT2*THK_PRT2*RHO_PRT2*SHC_PRT2
ELSE
RK_2ND_DENOM2 = 0._EB
ENDIF

RK_2ND_DENOM = THK_STEEL*RHO_STEEL*SHC_STEEL + RK_2ND_DENOM1 + RK_2ND_DENOM2

! net heat transfer terms for protection 1+2
CALL NET_RK (RK_2ND_NET1,HTC_EFF,TMP_GAS1,TMP_SURF(1,IRNK),Q_RAD1,EMSV_MBR1,SIGMA)
CALL NET_RK (RK_2ND_NET2,HTC_EFF,TMP_GAS2,TMP_SURF(2,IRNK),Q_RAD2,EMSV_MBR2,SIGMA)
RK_2ND_NET = (RK_2ND_NET1 + RK_2ND_NET2) / RK_2ND_DENOM  

IF ((THK_PRT1 + THK_PRT2) > 0) THEN  ! transient terms only apply if there is a protective layer
CALL TRANS_RK (RK_2ND_TRNS1,TMP_SURF(1,IRNK),PRT1_TMP(I_GS,J_GS,K_GS),THK_PRT1,WF_PRT1,RHO_PRT1,SHC_PRT1,DT_GS,DTMP_LIM)
CALL TRANS_RK (RK_2ND_TRNS2,TMP_SURF(2,IRNK),PRT2_TMP(I_GS,J_GS,K_GS),THK_PRT2,WF_PRT2,RHO_PRT2,SHC_PRT2,DT_GS,DTMP_LIM)

RK_2ND_TRNS = (RK_2ND_TRNS1 + RK_2ND_TRNS2) / RK_2ND_DENOM
ELSE
RK_2ND_TRNS = 0._EB
ENDIF

RK_2NDF = RK_2ND_NET + MIN(MAX(RK_2ND_TRNS, -RK_2ND_NET), RK_2ND_NET)

! Find ratio of axial correction to uncorrected function; if correction is too big, do not include to avoid divergence 
PER_TMP_AX = ABS((AX_UP-AX_LOW)/RK_2ND_DENOM) / RK_2NDF

IF (PER_TMP_AX > 0.5) CORRECTION = .FALSE.

IF (CORRECTION) RK_2NDF_AX = RK_2ND_NET + MIN(MAX(RK_2ND_TRNS, -RK_2ND_NET), RK_2ND_NET) + (AX_UP-AX_LOW)/RK_2ND_DENOM

RK_2ND = DT_GS*RK_2NDF

IF (CORRECTION) RK_2ND = DT_GS*RK_2NDF_AX

TMP_STEEL = MIN (TMP_UPLIM, MAX(STEEL_TMP(I_GS,J_GS,K_GS)+(RK_1ST+RK_2ND)/2._EB, TMP_MBR0))

IF (CORRECTION) TMP_STEEL_AX = MIN (TMP_UPLIM, MAX(STEEL_TMP(I_GS,J_GS,K_GS)+(RK_1ST_AX+RK_2ND_AX)/2._EB, TMP_MBR0))


!---------------------------------------CORRECTIONS FOR END EFFECT AND JUNCTION EFFECT--------------------------------------------!

! NOTE: Original code activates all the correction terms or none, because the axial gradient corrections are used
! Investigate- is it suitable to use individual switches for each correction effect?

CORREND = .FALSE.
CORRJUNC = .FALSE.

! End effect follows simplified equation given in Table 3.3 of GeniSTELA PhD
! Depends on RK_1ST and RK_2ND, values, so is affected by whether axial correction applied or not
IF (CORREND) THEN
IF (CORRECTION) THEN
TMP_S_END = MIN((TMP_UPLIM-TMP_STEEL), MAX(0.5*(RK_1STF_AX+RK_2NDF_AX), (TMPA-TMP_STEEL_AX))) * 2._EB*THK_FL/WD_FL

ELSE
TMP_S_END = MIN((TMP_UPLIM-TMP_STEEL), MAX(0.5*(RK_1STF+RK_2NDF), (TMPA-TMP_STEEL))) * 2._EB*THK_FL/WD_FL

END IF

! Do not apply correction effect if the value is too small or large
IF (TMP_S_END < 1.0E-2 .OR. TMP_S_END > 100._EB) TMP_S_END = 0._EB

END IF

! Junction effect follows equation and variable derivation shown in Section 3.3.1 of GeniSTELA PhD
CHI_JUNC = (4._EB*THK_WEB*THK_FL)/(2._EB*THK_FL*WD_WEB + THK_WEB*WD_FL)  ! length scale parameter
IF (CORRJUNC) THEN
IF (CORRECTION) THEN
TMP_STEEL_MID = TMP_STEEL_AX
ELSE
TMP_STEEL_MID = TMP_STEEL
END IF

Q_JUNC = K_STEEL*THK_WEB/(WD_FL*WD_WEB) * (TMP_STEEL_MID - TMPA) * (1._EB - HTC_EFF*WD_WEB/K_STEEL) + &
THK_WEB/WD_FL * EMSV_MBR1*SIGMA*(TMPA**4 - TMP_STEEL_MID**4)  ! junction heat flux

TMP_S_JUNC = Q_JUNC*CHI_JUNC/K_STEEL

IF (TMP_S_JUNC < 1.0E-2 .OR. TMP_S_JUNC > 100._EB) TMP_S_JUNC = 0._EB

END IF

!----------------------------------------FINAL TEMPERATURE FOR STEEL AND PROTECTIVE LAYERS----------------------------------------!

IF (CORRECTION) THEN
STEEL_TMP(I_GS,J_GS,K_GS) = MAX( (TMP_STEEL_AX+TMP_S_END+TMP_S_JUNC), TMP_MBR0)

ELSE
STEEL_TMP(I_GS,J_GS,K_GS) = MAX(TMP_STEEL, TMP_MBR0)

ENDIF

IF (THK_PRT1 + THK_PRT2 > 0) THEN  ! appears superfluous, but is likely to be an 'error trap'
PRT1_TMP(I_GS,J_GS,K_GS) = TMP_SURF(1,IRNK)
PRT2_TMP(I_GS,J_GS,K_GS) = TMP_SURF(2,IRNK)

ELSE
PRT1_TMP(I_GS,J_GS,K_GS) = TMP_SURF(1,IRNK)
PRT2_TMP(I_GS,J_GS,K_GS) = TMP_SURF(2,IRNK)

ENDIF

ELSE
STEEL_TMP(I_GS,J_GS,K_GS) = -1 ! if cell is blocked, this should indicate that a temperature was not found
PRT1_TMP(I_GS,J_GS,K_GS) = -1
PRT2_TMP(I_GS,J_GS,K_GS) = -1
ENDIF


!-------------------------------------------------OUTPUT RESULTS TO FILE----------------------------------------------------------!

! IJK must be expressed as REAL variables for output to read values correctly
! convert cell number to end face coordinate (in m) using cell size and offset by coordinate of first point
IPOS = REAL(I_GS)*M%DX(I_GS) + M%XS
JPOS = REAL(J_GS)*M%DY(J_GS) + M%YS
KPOS = REAL(K_GS)*M%DZ(K_GS) + M%ZS

SIMTIME = REAL(T_BEGIN+(T-T_BEGIN)*TIME_SHRINK_FACTOR,FB)

! MANUALLY INSERT CELL RANGE FOR TEMPERATURE ACROSS POSITIONS
! This example is for a section covering 0.5m along starting from centre, full width and height of beam
IF (IPOS .GE. (1.475-M%DX(I_GS)) .AND. IPOS .LE. (1.975+M%DX(I_GS))) THEN
IF (JPOS .GE. (0.79-M%DY(J_GS)) .AND. JPOS .LE. (1.04+M%DY(J_GS))) THEN
IF (KPOS .GE. (1.0+M%DZ(K_GS)) .AND. KPOS .LE. (1.275+M%DZ(K_GS))) THEN

WRITE(CSVDFMT,'(A,I5.1,5A)') "(",7,"(",FMT_R,",','),",FMT_R,")" ! use this to set style for lines to follow
WRITE(LU_GSTA(NM),CSVDFMT) IPOS,JPOS,KPOS,STEEL_TMP(I_GS,J_GS,K_GS),PRT1_TMP(I_GS,J_GS,K_GS),PRT2_TMP(I_GS,J_GS,K_GS),SIMTIME

ENDIF
ENDIF
ENDIF

! MANUALLY INSERT CELL RANGE FOR TIME HISTORY
! This example is for the single point (2.05, 1.04, 1.075) that lies on the beam 'surface'
IF ((IPOS-2.05) .GE. 0 .AND.  (IPOS-2.05) < M%DX(I_GS)) THEN
IF ((JPOS-1.04) .GE. 0 .AND. (JPOS-1.04) < M%DY(J_GS)) THEN
IF ((KPOS-1.075) .GE. 0 .AND. (KPOS-1.075) < M%DZ(K_GS)) THEN

WRITE(CSVDFMT,'(A,I5.1,5A)') "(",46,"(",FMT_R,",','),",FMT_R,")"
WRITE(LU_GSTH(NM),CSVDFMT) SIMTIME,DT_GS,STEEL_TMP(I_GS,J_GS,K_GS),PRT1_TMP(I_GS,J_GS,K_GS),PRT2_TMP(I_GS,J_GS,K_GS),&
IPOS,JPOS,KPOS,M%TMP(I_GS,J_GS,K_GS),M%U(I_GS,J_GS,K_GS),M%V(I_GS,J_GS,K_GS),M%W(I_GS,J_GS,K_GS),M%RHO(I_GS,J_GS,K_GS),SHC_GAS,&
RADSUM,Q_RAD,VEL_MEAN,VISC_DYN,RE_NO,GR_NO,NU_NO,HTC_EFF,SIZE(TMP_INT_SURF,2),K_INT_PRT1,SHC_INT_PRT1,RHO_INT_PRT1,WF_INT_PRT1,&
TMP_SURF(1,0),SHC_STEEL_INT,RK_1ST_DENOM,RK_1ST_NET,RK_1ST_TRNS,RK_1STF,RK_1ST,SIZE(TMP_SURF,2),K_PRT1,SHC_PRT1,RHO_PRT1,WF_PRT1,&
TMP_SURF(1,IRNK),SHC_STEEL,RK_2ND_DENOM,RK_2ND_NET,RK_2ND_TRNS,RK_2NDF,RK_2ND


ENDIF
ENDIF
ENDIF

ENDDO
ENDDO
ENDDO

! deallocate the arrays to free the memory
DEALLOCATE (STEEL_TMP)
DEALLOCATE (PRT1_TMP)
DEALLOCATE (PRT2_TMP)

RETURN
END SUBROUTINE GENISTELA


SUBROUTINE INTUMESCE (CP_PROT, K_PROT, RHO_PROT, RHO_DRY, FAC_EXP, TMP_PROT) 
! CHECK SECTION 3.6.2 OF GENISTELA PHD PAPER FOR THEORY AND EXPLANATIONS
REAL(EB) :: CP_PROT, K_PROT, RHO_PROT, RHO_DRY, FAC_EXP, TMP_PROT, &
MASSRATE, FAC_EXP_T, K_DRY, TMP_IMID, TMP_ILOW, TMP_IHIGH, CP_DRY  ! properties
REAL(EB) ::  SFPWR, K_FAC, KTMP, KPOLY2=1.32E-6, KPOLY1=3.08E-3, KPOLY0=5.97E-2, ENGY  ! factors and powers

TMP_ILOW = 200._EB + TMPM  ! convert to Kelvin
TMP_IHIGH = 600._EB + TMPM  ! convert to Kelvin
CP_DRY = 970._EB
K_DRY = 0.163422917_EB  ! W/(m.K)
TMP_IMID = (TMP_ILOW + TMP_IHIGH)/2

SFPWR = 2._EB
ENGY = 2._EB * EXP(6.0)
KTMP = 3._EB * EXP(-6.0)

! MASS CHANGE RATE
IF (TMP_PROT < TMP_ILOW) THEN
MASSRATE = 1._EB

ELSE IF (TMP_PROT < TMP_IMID) THEN
MASSRATE = 1._EB - 0.5_EB*(1._EB - 1._EB/FAC_EXP)*((TMP_PROT - TMP_ILOW)/(TMP_IMID - TMP_ILOW))**SFPWR

ELSE IF (TMP_PROT < TMP_IHIGH) THEN
MASSRATE = 1/FAC_EXP + 0.5_EB*(1._EB - 1._EB/FAC_EXP)*((TMP_IHIGH - TMP_PROT)/(TMP_IHIGH - TMP_IMID))**SFPWR

ELSE 
MASSRATE = 1._EB/FAC_EXP
 ENDIF
 
 ! EXPANSION RATIO (TIME-DEPENDENT FACTOR)
 IF (TMP_PROT < TMP_ILOW) THEN
FAC_EXP_T = 1._EB

ELSE IF (TMP_PROT < TMP_IMID) THEN
FAC_EXP_T = 1._EB + 0.5_EB*(FAC_EXP - 1._EB) * ((TMP_PROT - TMP_ILOW)/(TMP_IMID - TMP_ILOW))**SFPWR

ELSE IF (TMP_PROT < TMP_IHIGH) THEN
FAC_EXP_T = FAC_EXP - 0.5_EB*(FAC_EXP - 1._EB) * ((TMP_IHIGH - TMP_PROT)/(TMP_IHIGH - TMP_IMID))**SFPWR

ELSE 
FAC_EXP_T = FAC_EXP
 ENDIF
 
 !  TEMPERATURE-VARYING AND EFFECTIVE THERMAL CONDUCTIVITY
 K_FAC = K_DRY + KTMP*TMP_PROT
 K_PROT = K_FAC * (KPOLY2*TMP_PROT**2*KPOLY1*TMP_PROT+KPOLY0)
 K_PROT = K_PROT*FAC_EXP_T

RHO_PROT = MASSRATE*RHO_DRY  ! EFFECTIVE DENSITY

! SPECIFIC HEAT CAPACITY
 IF (TMP_PROT < TMP_ILOW) THEN
CP_PROT = FAC_EXP_T*CP_DRY

ELSE IF (TMP_PROT < TMP_IMID) THEN
CP_PROT = FAC_EXP_T*CP_DRY
CP_PROT = CP_PROT + 1._EB/(0.5_EB*(TMP_ILOW + TMP_IMID)) * ( TMP_PROT/(0.5_EB*(TMP_ILOW + TMP_IMID)) - 0.5_EB) * ENGY

ELSE IF (TMP_PROT < TMP_IHIGH) THEN
CP_PROT = FAC_EXP_T*CP_DRY
CP_PROT = CP_PROT - 1._EB/(0.5_EB*(TMP_ILOW + TMP_IMID)) * ( TMP_PROT/(0.5_EB*(TMP_ILOW + TMP_IMID)) - 2.5_EB) * ENGY

ELSE 
CP_PROT = FAC_EXP*CP_DRY

ENDIF

END SUBROUTINE INTUMESCE

SUBROUTINE MOISTURE (K_PROT, CP_PROT, TMP_PROT, TMP_INIT, TMP_UP)
! CHECK SECTION SECTION 3.6.1 OF GENISTELA PHD FOR THEORY AND EXPLANATIONS
REAL(EB) :: K_PROT, CP_PROT, TMP_PROT, TMP_INIT, TMP_UP, &
LH_H20, TMP_ZERO, TMP_MID, K_PEAK, K_BASE, CP_DRY, MOIST, CP_H20  ! properties
REAL(EB) ::   KTMP, K_FAC, K_PWR ! factors and powers
LOGICAL :: MOIST_FLAG
 
LH_H20 = 2.18E6  ! latent heat of water in J/kg
TMP_ZERO = TMPM  ! lowest temperature is 0C = 273.15K
TMP_MID = (TMP_INIT + TMP_UP)/2
CP_H20 = 1000._EB  ! specific heat capacity of water
K_BASE = 0.163422917_EB ! assume same value as equivalent variable for intumescent
CP_DRY = 970._EB
MOIST = 0.01_EB

KTMP = 1.06E-3
K_FAC = 1._EB
K_PWR = 1._EB

! IF (MOIST .NE. 0) MOIST_FLAG = .TRUE.  ! moisture effects not applicable if moisture not transferred
MOIST_FLAG = .FALSE.  ! flag for moisture effect on thermal conductivity is manually set (SensVari input file in original code)

! SPECIFIC HEAT CAPACITY
IF (TMP_PROT .GE. TMP_UP) THEN
CP_PROT = CP_DRY

ELSEIF (TMP_PROT .GE. TMP_MID) THEN
CP_PROT = CP_DRY + MOIST * (4*LH_H20*(TMP_UP - TMP_PROT)/((TMP_UP - TMP_INIT)**2) &
+ CP_H20 * (TMP_UP - TMP_PROT)/(TMP_UP - TMP_INIT))

ELSEIF (TMP_PROT .GE. TMP_INIT) THEN
CP_PROT = CP_DRY + MOIST * (4*LH_H20*(TMP_PROT - TMP_INIT)/((TMP_UP - TMP_INIT)**2) &
+ CP_H20 * (TMP_UP - TMP_PROT)/(TMP_UP - TMP_INIT))

ELSEIF (TMP_PROT .GE. TMP_ZERO) THEN
CP_PROT = CP_DRY + CP_H20*MOIST

ENDIF

! THERMAL CONDUCTIVITY
IF (MOIST_FLAG) THEN
K_PEAK = (K_BASE + KTMP * (TMP_PROT - TMP_ZERO)) * (MOIST * K_FAC**(K_PWR) + 1._EB)**(1._EB/K_PWR)

ELSE
K_PEAK = K_BASE + KTMP * (TMP_PROT - TMP_ZERO)

ENDIF

IF (TMP_PROT .GE. TMP_UP) THEN
K_PROT = K_BASE + KTMP * (TMP_PROT - TMP_ZERO) 

ELSEIF (TMP_PROT .GE. TMP_INIT) THEN
K_PROT = (TMP_UP - TMP_PROT)/(TMP_UP - TMP_INIT) * (K_PEAK - (K_BASE + KTMP * (TMP_PROT - TMP_ZERO))) &
+  K_BASE + KTMP * (TMP_PROT - TMP_ZERO)

ELSEIF (TMP_PROT .GE. TMP_ZERO) THEN
K_PROT = (TMP_PROT - TMP_ZERO)/(TMP_INIT - TMP_ZERO) * (K_PEAK - (K_BASE + KTMP * (TMP_PROT - TMP_ZERO))) &
+  K_BASE + KTMP * (TMP_PROT - TMP_ZERO)

ENDIF

END SUBROUTINE MOISTURE

SUBROUTINE BOUND_CONDN(NUM_NR,TMP_FACE,HTC_MBR,TMP_GAS,TMP_STEEL,RAD_HEAT_FLUX,EMSV_MBR,SIGMA,K_PRT,THK_PRT,WF_PRT)

REAL(EB), INTENT(IN) :: TMP_FACE,HTC_MBR,TMP_GAS,TMP_STEEL,RAD_HEAT_FLUX,EMSV_MBR,SIGMA,K_PRT,THK_PRT,WF_PRT 
REAL(EB) :: NUM_NR

NUM_NR = -EMSV_MBR*SIGMA*TMP_FACE**4 - HTC_MBR*TMP_FACE - (K_PRT/(WF_PRT*THK_PRT))*TMP_FACE + HTC_MBR*TMP_GAS + &
EMSV_MBR*RAD_HEAT_FLUX + (K_PRT/(WF_PRT*THK_PRT))*TMP_STEEL

END SUBROUTINE BOUND_CONDN

SUBROUTINE BOUND_CONDN_PRIME(DENOM_NR,TMP_FACE,HTC_MBR,SIGMA,EMSV_MBR,K_PRT,WF_PRT,THK_PRT)

REAL(EB),INTENT(IN) :: TMP_FACE,HTC_MBR,SIGMA,EMSV_MBR,K_PRT,WF_PRT,THK_PRT
REAL(EB) :: DENOM_NR

DENOM_NR = -4._EB*EMSV_MBR*SIGMA*TMP_FACE**3 - HTC_MBR - K_PRT/(WF_PRT*THK_PRT)

END SUBROUTINE BOUND_CONDN_PRIME

SUBROUTINE NET_RK(RK_FNET,HTC_MBR,TMP_GAS,TMP_FACE,RAD_HEAT_FLUX,EMSV_MBR,SIGMA)
REAL(EB),INTENT(IN) :: HTC_MBR,TMP_GAS,TMP_FACE,RAD_HEAT_FLUX,EMSV_MBR,SIGMA
REAL(EB) :: RK_FNET

RK_FNET = HTC_MBR*(TMP_GAS - TMP_FACE) + EMSV_MBR*RAD_HEAT_FLUX - EMSV_MBR*SIGMA*TMP_FACE**4

END SUBROUTINE NET_RK

SUBROUTINE TRANS_RK(RK_FTRN,TMP_FACE,TMP_FACE_OLD,THK_PRT,WF_PRT,RHO_PRT,SHC_PRT,TIMESTEP,DTMP_LIM)
REAL(EB),INTENT(IN) :: TMP_FACE,TMP_FACE_OLD,THK_PRT,WF_PRT,RHO_PRT,SHC_PRT,TIMESTEP,DTMP_LIM
REAL(EB) :: RK_FTRN

RK_FTRN = -0.5_EB*MAX((TMP_FACE - TMP_FACE_OLD),DTMP_LIM)*(THK_PRT*WF_PRT*RHO_PRT*SHC_PRT/TIMESTEP)

END SUBROUTINE TRANS_RK

SUBROUTINE CPSTEEL(CP_STEEL, TMP_STEEL)
REAL(EB), INTENT(IN) :: TMP_STEEL
REAL(EB) :: TMP_DEGC
REAL(EB) :: CP_STEEL

TMP_DEGC = TMP_STEEL - TMPM  ! convert steel temp (K) to perform calculations in degC

IF (TMP_STEEL > 1173.15) THEN
CP_STEEL = 650._EB

ELSEIF (TMP_STEEL > 1008.15) THEN
CP_STEEL = 545._EB + 17820._EB/(TMP_DEGC-731._EB)

ELSEIF (TMP_STEEL > 873.15) THEN
CP_STEEL = 666._EB + 13002._EB/(738._EB-TMP_DEGC)

ELSEIF (TMP_STEEL > 293.15) THEN
CP_STEEL = 425._EB + 7.73E-1*TMP_DEGC - 1.69E-3*TMP_DEGC**2 + 2.22E-6*TMP_DEGC**3

ELSE
CP_STEEL = 425._EB
ENDIF

END SUBROUTINE CPSTEEL


!//////////////////////////////////////////////////////////////////////////////////////////////////////
! Supporting routines as usual listed below

SUBROUTINE CHECK_MPI

! Check the threading support level

IF (PROVIDED<REQUIRED) THEN
   IF (MYID==0) WRITE(LU_ERR,'(A)') ' WARNING:  This MPI implementation provides insufficient threading support.'
   !$ CALL OMP_SET_NUM_THREADS(1)
ENDIF

END SUBROUTINE CHECK_MPI


SUBROUTINE MPI_INITIALIZATION_CHORES(TASK_NUMBER)

INTEGER, INTENT(IN) :: TASK_NUMBER
INTEGER, ALLOCATABLE, DIMENSION(:) :: REQ0
INTEGER :: N_REQ0

SELECT CASE(TASK_NUMBER)

   CASE(1)

      ! Set up send and receive buffer counts and displacements

      ALLOCATE(REAL_BUFFER_1((2+N_TRACKED_SPECIES)*N_DUCTNODES+N_DUCTS))
      ALLOCATE(REAL_BUFFER_2(10,NMESHES))
      ALLOCATE(REAL_BUFFER_3(10,NMESHES))
      ALLOCATE(REAL_BUFFER_5(0:N_SPECIES,NMESHES))
      ALLOCATE(REAL_BUFFER_6((9+N_TRACKED_SPECIES)*N_DUCTNODES,NMESHES))
      ALLOCATE(REAL_BUFFER_8((9+N_TRACKED_SPECIES)*N_DUCTNODES,NMESHES))
      ALLOCATE(REAL_BUFFER_11(N_Q_DOT+N_M_DOT,NMESHES))
      ALLOCATE(REAL_BUFFER_12(N_Q_DOT+N_M_DOT,NMESHES))
      ALLOCATE(REAL_BUFFER_13(20,NMESHES))
      ALLOCATE(REAL_BUFFER_14(20,NMESHES))

      ALLOCATE(COUNTS(0:N_MPI_PROCESSES-1))
      ALLOCATE(COUNTS_HVAC(0:N_MPI_PROCESSES-1))
      ALLOCATE(COUNTS_MASS(0:N_MPI_PROCESSES-1))
      ALLOCATE(COUNTS_QM_DOT(0:N_MPI_PROCESSES-1))
      ALLOCATE(COUNTS_TEN(0:N_MPI_PROCESSES-1))
      ALLOCATE(COUNTS_TWENTY(0:N_MPI_PROCESSES-1))

      ALLOCATE(DISPLS(0:N_MPI_PROCESSES-1))
      ALLOCATE(DISPLS_MASS(0:N_MPI_PROCESSES-1))
      ALLOCATE(DISPLS_HVAC(0:N_MPI_PROCESSES-1))
      ALLOCATE(DISPLS_QM_DOT(0:N_MPI_PROCESSES-1))
      ALLOCATE(DISPLS_TEN(0:N_MPI_PROCESSES-1))
      ALLOCATE(DISPLS_TWENTY(0:N_MPI_PROCESSES-1))

      COUNTS    = 0
      DO N=0,N_MPI_PROCESSES-1
         DO NM=1,NMESHES
            IF (PROCESS(NM)==N) COUNTS(N)    = COUNTS(N)    + 1
         ENDDO
      ENDDO
      DISPLS(0)    = 0
      DO N=1,N_MPI_PROCESSES-1
         DISPLS(N)    = COUNTS(N-1)    + DISPLS(N-1)
      ENDDO
      COUNTS_HVAC   = COUNTS*((9+N_TRACKED_SPECIES)*N_DUCTNODES)
      DISPLS_HVAC   = DISPLS*((9+N_TRACKED_SPECIES)*N_DUCTNODES)
      COUNTS_MASS   = COUNTS*(N_SPECIES+1)
      DISPLS_MASS   = DISPLS*(N_SPECIES+1)
      COUNTS_QM_DOT = COUNTS*(N_Q_DOT+N_M_DOT)
      DISPLS_QM_DOT = DISPLS*(N_Q_DOT+N_M_DOT)
      COUNTS_TEN    = COUNTS*10
      DISPLS_TEN    = DISPLS*10
      COUNTS_TWENTY = COUNTS*20
      DISPLS_TWENTY = DISPLS*20

   CASE(2)

      ! Allocate TIME arrays

      ALLOCATE(DT_NEW(NMESHES),STAT=IZERO) ;  CALL ChkMemErr('MAIN','DT_NEW',IZERO) ; DT_NEW = DT

      ! Set up dummy arrays to hold various arrays that must be exchanged among meshes

      ALLOCATE(TI_LOC(N_DEVC),STAT=IZERO)
      CALL ChkMemErr('MAIN','TI_LOC',IZERO)
      ALLOCATE(TI_GLB(N_DEVC),STAT=IZERO)
      CALL ChkMemErr('MAIN','TI_GLB',IZERO)
      ALLOCATE(STATE_GLB(2*N_DEVC),STAT=IZERO)
      CALL ChkMemErr('MAIN','STATE_GLB',IZERO)
      ALLOCATE(STATE_LOC(2*N_DEVC),STAT=IZERO)
      CALL ChkMemErr('MAIN','STATE_LOC',IZERO)
      ALLOCATE(TC_GLB(3*N_DEVC),STAT=IZERO)
      CALL ChkMemErr('MAIN','TC_GLB',IZERO)
      ALLOCATE(TC_LOC(3*N_DEVC),STAT=IZERO)
      CALL ChkMemErr('MAIN','TC_LOC',IZERO)
      ALLOCATE(TC2_GLB(2,N_DEVC),STAT=IZERO)
      CALL ChkMemErr('MAIN','TC2_GLB',IZERO)
      ALLOCATE(TC2_LOC(2,N_DEVC),STAT=IZERO)
      CALL ChkMemErr('MAIN','TC2_LOC',IZERO)

      ! Allocate a few arrays needed to exchange divergence and pressure info among meshes

      IF (N_ZONE > 0) THEN
         ALLOCATE(DSUM_ALL(N_ZONE),STAT=IZERO)
         ALLOCATE(PSUM_ALL(N_ZONE),STAT=IZERO)
         ALLOCATE(USUM_ALL(N_ZONE),STAT=IZERO)
         ALLOCATE(CONNECTED_ZONES_GLOBAL(0:N_ZONE,0:N_ZONE),STAT=IZERO)
         ALLOCATE(DSUM_ALL_LOCAL(N_ZONE),STAT=IZERO)
         ALLOCATE(PSUM_ALL_LOCAL(N_ZONE),STAT=IZERO)
         ALLOCATE(USUM_ALL_LOCAL(N_ZONE),STAT=IZERO)
         ALLOCATE(CONNECTED_ZONES_LOCAL(0:N_ZONE,0:N_ZONE),STAT=IZERO)
      ENDIF

   CASE(3)

      ! Allocate "request" arrays to keep track of MPI communications

      ALLOCATE(REQ(N_COMMUNICATIONS*40))
      ALLOCATE(REQ1(N_COMMUNICATIONS*4))
      ALLOCATE(REQ2(N_COMMUNICATIONS*4))
      ALLOCATE(REQ3(N_COMMUNICATIONS*4))
      ALLOCATE(REQ4(N_COMMUNICATIONS*4))
      ALLOCATE(REQ5(N_COMMUNICATIONS*4))
      ALLOCATE(REQ6(N_COMMUNICATIONS*4))
      ALLOCATE(REQ7(N_COMMUNICATIONS*4))
      ALLOCATE(REQ8(N_COMMUNICATIONS*4))
      ALLOCATE(REQ14(N_COMMUNICATIONS*4))

      REQ = MPI_REQUEST_NULL
      REQ1 = MPI_REQUEST_NULL
      REQ2 = MPI_REQUEST_NULL
      REQ3 = MPI_REQUEST_NULL
      REQ4 = MPI_REQUEST_NULL
      REQ5 = MPI_REQUEST_NULL
      REQ6 = MPI_REQUEST_NULL
      REQ7 = MPI_REQUEST_NULL
      REQ8 = MPI_REQUEST_NULL
      REQ14 = MPI_REQUEST_NULL

   CASE(4)

      IF (N_MPI_PROCESSES>1) THEN

         ALLOCATE(REQ0(NMESHES**2)) ; N_REQ0 = 0

         DO NM=1,NMESHES
            IF (EVACUATION_ONLY(NM)) CYCLE
            DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
               IF (EVACUATION_ONLY(NOM)) CYCLE
               IF (NM/=NOM .AND. PROCESS(NM)/=MYID .AND. MESHES(NOM)%CONNECTED_MESH(NM)) THEN
                  M2 => MESHES(NOM)%OMESH(NM)
                  N_REQ0 = N_REQ0 + 1
                  CALL MPI_IRECV(M2%INTEGER_RECV_BUFFER(1),7,MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0),IERR)
               ENDIF
            ENDDO
         ENDDO

      ENDIF


      ! DEFINITION NIC_S:   MESHES(NOM)%OMESH(NM)%NIC_S   = MESHES(NM)%OMESH(NOM)%NIC_R
      ! DEFINITION I_MIN_S: MESHES(NOM)%OMESH(NM)%I_MIN_S = MESHES(NM)%OMESH(NOM)%I_MIN_R
      ! DEFINITION I_MAX_S: MESHES(NOM)%OMESH(NM)%I_MAX_S = MESHES(NM)%OMESH(NOM)%I_MAX_R
      ! DEFINITION J_MIN_S: MESHES(NOM)%OMESH(NM)%J_MIN_S = MESHES(NM)%OMESH(NOM)%J_MIN_R
      ! DEFINITION J_MAX_S: MESHES(NOM)%OMESH(NM)%J_MAX_S = MESHES(NM)%OMESH(NOM)%J_MAX_R
      ! DEFINITION K_MIN_S: MESHES(NOM)%OMESH(NM)%K_MIN_S = MESHES(NM)%OMESH(NOM)%K_MIN_R
      ! DEFINITION K_MAX_S: MESHES(NOM)%OMESH(NM)%K_MAX_S = MESHES(NM)%OMESH(NOM)%K_MAX_R

      DO NM=1,NMESHES
         IF (PROCESS(NM)/=MYID) CYCLE
         IF (EVACUATION_ONLY(NM)) CYCLE
         DO NOM=1,NMESHES
            IF (EVACUATION_ONLY(NOM)) CYCLE
            IF (.NOT.MESHES(NM)%CONNECTED_MESH(NOM)) CYCLE
            M3 => MESHES(NM)%OMESH(NOM)
            IF (N_MPI_PROCESSES>1 .AND. NM/=NOM .AND. PROCESS(NOM)/=MYID .AND. MESHES(NM)%CONNECTED_MESH(NOM)) THEN
               M3%INTEGER_SEND_BUFFER(1) = M3%I_MIN_R
               M3%INTEGER_SEND_BUFFER(2) = M3%I_MAX_R
               M3%INTEGER_SEND_BUFFER(3) = M3%J_MIN_R
               M3%INTEGER_SEND_BUFFER(4) = M3%J_MAX_R
               M3%INTEGER_SEND_BUFFER(5) = M3%K_MIN_R
               M3%INTEGER_SEND_BUFFER(6) = M3%K_MAX_R
               M3%INTEGER_SEND_BUFFER(7) = M3%NIC_R
               N_REQ0 = N_REQ0 + 1
               CALL MPI_ISEND(M3%INTEGER_SEND_BUFFER(1),7,MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0),IERR)
            ELSE
               M2 => MESHES(NOM)%OMESH(NM)
               M2%I_MIN_S = M3%I_MIN_R
               M2%I_MAX_S = M3%I_MAX_R
               M2%J_MIN_S = M3%J_MIN_R
               M2%J_MAX_S = M3%J_MAX_R
               M2%K_MIN_S = M3%K_MIN_R
               M2%K_MAX_S = M3%K_MAX_R
               M2%NIC_S   = M3%NIC_R
            ENDIF
         ENDDO
      ENDDO

      IF (N_MPI_PROCESSES>1) THEN

         CALL MPI_WAITALL(N_REQ0,REQ0(1:N_REQ0),MPI_STATUSES_IGNORE,IERR)

         DO NM=1,NMESHES
            IF (EVACUATION_ONLY(NM)) CYCLE
            DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
               IF (EVACUATION_ONLY(NOM)) CYCLE
               IF (NM/=NOM .AND. PROCESS(NM)/=MYID .AND. MESHES(NOM)%CONNECTED_MESH(NM)) THEN
                  M2 => MESHES(NOM)%OMESH(NM)
                  M2%I_MIN_S = M2%INTEGER_RECV_BUFFER(1)
                  M2%I_MAX_S = M2%INTEGER_RECV_BUFFER(2)
                  M2%J_MIN_S = M2%INTEGER_RECV_BUFFER(3)
                  M2%J_MAX_S = M2%INTEGER_RECV_BUFFER(4)
                  M2%K_MIN_S = M2%INTEGER_RECV_BUFFER(5)
                  M2%K_MAX_S = M2%INTEGER_RECV_BUFFER(6)
                  M2%NIC_S   = M2%INTEGER_RECV_BUFFER(7)
               ENDIF
            ENDDO
         ENDDO

         DEALLOCATE(REQ0)

      ENDIF

      ! Exchange IIO_S, etc., the indices of interpolated cells
      ! DEFINITION IIO_S: MESHES(NOM)%OMESH(NM)%IIO_S = MESHES(NM)%OMESH(NOM)%IIO_R
      ! DEFINITION JJO_S: MESHES(NOM)%OMESH(NM)%JJO_S = MESHES(NM)%OMESH(NOM)%JJO_R
      ! DEFINITION KKO_S: MESHES(NOM)%OMESH(NM)%KKO_S = MESHES(NM)%OMESH(NOM)%KKO_R
      ! DEFINITION IOR_S: MESHES(NOM)%OMESH(NM)%IOR_S = MESHES(NM)%OMESH(NOM)%IOR_R

      DO NM=1,NMESHES
         IF (EVACUATION_ONLY(NM)) CYCLE
         DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
            IF (EVACUATION_ONLY(NOM)) CYCLE
            IF (MESHES(NOM)%OMESH(NM)%NIC_S>0) THEN
               M2 => MESHES(NOM)%OMESH(NM)
               ALLOCATE(M2%IIO_S(M2%NIC_S))
               ALLOCATE(M2%JJO_S(M2%NIC_S))
               ALLOCATE(M2%KKO_S(M2%NIC_S))
               ALLOCATE(M2%IOR_S(M2%NIC_S))
            ENDIF
         ENDDO
      ENDDO

      N_REQ = 0

      DO NM=1,NMESHES
         IF (EVACUATION_ONLY(NM)) CYCLE
         DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
            IF (EVACUATION_ONLY(NOM)) CYCLE
            M2 => MESHES(NOM)%OMESH(NM)
            IF (N_MPI_PROCESSES>1 .AND. NM/=NOM .AND. PROCESS(NM)/=MYID .AND. M2%NIC_S>0) THEN
               CALL MPI_IRECV(M2%IIO_S(1),M2%NIC_S,MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ(N_REQ+1),IERR)
               CALL MPI_IRECV(M2%JJO_S(1),M2%NIC_S,MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ(N_REQ+2),IERR)
               CALL MPI_IRECV(M2%KKO_S(1),M2%NIC_S,MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ(N_REQ+3),IERR)
               CALL MPI_IRECV(M2%IOR_S(1),M2%NIC_S,MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ(N_REQ+4),IERR)
               N_REQ = N_REQ + 4
            ENDIF
         ENDDO
      ENDDO

      DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (EVACUATION_ONLY(NM)) CYCLE
         DO NOM=1,NMESHES
            IF (EVACUATION_ONLY(NOM)) CYCLE
            M3 => MESHES(NM)%OMESH(NOM)
            IF (M3%NIC_R<1) CYCLE
            IF (PROCESS(NOM)/=MYID) THEN
               CALL MPI_ISEND(M3%IIO_R(1),M3%NIC_R,MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ(N_REQ+1),IERR)
               CALL MPI_ISEND(M3%JJO_R(1),M3%NIC_R,MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ(N_REQ+2),IERR)
               CALL MPI_ISEND(M3%KKO_R(1),M3%NIC_R,MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ(N_REQ+3),IERR)
               CALL MPI_ISEND(M3%IOR_R(1),M3%NIC_R,MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ(N_REQ+4),IERR)
               N_REQ = N_REQ + 4
            ELSE
               M2 => MESHES(NOM)%OMESH(NM)
               M2%IIO_S = M3%IIO_R
               M2%JJO_S = M3%JJO_R
               M2%KKO_S = M3%KKO_R
               M2%IOR_S = M3%IOR_R
            ENDIF
         ENDDO
      ENDDO

      IF (N_REQ>0 .AND. N_MPI_PROCESSES>1) CALL MPI_WAITALL(N_REQ,REQ(1:N_REQ),MPI_STATUSES_IGNORE,IERR)

END SELECT

IF (MYID==0 .AND. VERBOSE) WRITE(LU_ERR,'(A,I2)') ' Completed Initialization Step ',TASK_NUMBER

END SUBROUTINE MPI_INITIALIZATION_CHORES


SUBROUTINE PRESSURE_ITERATION_SCHEME

! Iterate calls to pressure solver until velocity tolerance is satisfied

INTEGER :: NM_MAX_V,NM_MAX_P
REAL(EB) :: TNOW,VELOCITY_ERROR_MAX_OLD,PRESSURE_ERROR_MAX_OLD

PRESSURE_ITERATIONS = 0

IF (BAROCLINIC) THEN
   ITERATE_BAROCLINIC_TERM = .TRUE.
ELSE
   ITERATE_BAROCLINIC_TERM = .FALSE.
ENDIF

PRESSURE_ITERATION_LOOP: DO

   PRESSURE_ITERATIONS = PRESSURE_ITERATIONS + 1
   TOTAL_PRESSURE_ITERATIONS = TOTAL_PRESSURE_ITERATIONS + 1

   ! The following loops and exchange always get executed the first pass through the PRESSURE_ITERATION_LOOP.
   ! If we need to iterate the baroclinic torque term, the loop is executed each time.

   IF (ITERATE_BAROCLINIC_TERM .OR. PRESSURE_ITERATIONS==1) THEN
      DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (EVACUATION_ONLY(NM) .OR. EVACUATION_SKIP(NM)) CYCLE
         IF (BAROCLINIC) CALL BAROCLINIC_CORRECTION(T,NM)
      ENDDO
      CALL MESH_EXCHANGE(5)  ! Exchange FVX, FVY, FVZ
      DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
         IF (EVACUATION_ONLY(NM) .OR. EVACUATION_SKIP(NM)) CYCLE
         CALL MATCH_VELOCITY_FLUX(NM)
      ENDDO
   ENDIF

   ! Compute the right hand side (RHS) and boundary conditions for the Poission equation for pressure.
   ! The WALL_WORK1 array is computed in COMPUTE_VELOCITY_ERROR, but it should
   ! be zero the first time the pressure solver is called.

   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NM) .OR. EVACUATION_SKIP(NM)) CYCLE
      CALL NO_FLUX(DT,NM)
      IF (CC_IBM) THEN
         ! Wall model to define target velocities in gas cut faces.
         IF(PRESSURE_ITERATIONS==1. .AND. CC_FORCE_PRESSIT) CALL CCIBM_TARGET_VELOCITY(DT,NM)
         CALL CCIBM_NO_FLUX(DT,NM)
      ENDIF
      IF (PRESSURE_ITERATIONS==1) MESHES(NM)%WALL_WORK1 = 0._EB
      CALL PRESSURE_SOLVER_COMPUTE_RHS(T,NM)
   ENDDO

   ! Solve the Poission equation using either FFT, SCARC, or GLMAT

   SELECT CASE(PRES_METHOD)
      CASE ('FFT')
         DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
            IF (EVACUATION_ONLY(NM) .OR. EVACUATION_SKIP(NM)) CYCLE
            CALL PRESSURE_SOLVER_FFT(NM)
         ENDDO
      CASE ('SCARC','USCARC')
         CALL SCARC_SOLVER(DT)
         CALL STOP_CHECK(1)
      CASE ('GLMAT')
         CALL GLMAT_SOLVER_H
         CALL MESH_EXCHANGE(5)
         CALL COPY_H_OMESH_TO_MESH
   END SELECT

   ! Check the residuals of the Poisson solution

   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NM) .OR. EVACUATION_SKIP(NM)) CYCLE
      CALL PRESSURE_SOLVER_CHECK_RESIDUALS(NM)
   ENDDO


   IF (.NOT.ITERATE_PRESSURE) EXIT PRESSURE_ITERATION_LOOP

   ! Exchange both H or HS and FVX, FVY, FVZ and then estimate values of U, V, W (US, VS, WS) at next time step.

   CALL MESH_EXCHANGE(5)

   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NM) .OR. EVACUATION_SKIP(NM)) CYCLE
      CALL COMPUTE_VELOCITY_ERROR(DT,NM)
      IF (CC_IBM) THEN
         IF(CC_FORCE_PRESSIT) CALL CCIBM_TARGET_VELOCITY(DT,NM) ! Wall model to define n+1 target velocities in gas cut faces.
         CALL CCIBM_COMPUTE_VELOCITY_ERROR(DT,NM) ! Inside solids respect to zero velocity.
      ENDIF
   ENDDO

   ! Make all MPI processes aware of the maximum velocity error to decide if another pressure iteration is needed.

   IF (N_MPI_PROCESSES>1) THEN
      TNOW = CURRENT_TIME()
      REAL_BUFFER_2(1,:) = VELOCITY_ERROR_MAX(:)
      REAL_BUFFER_2(2,:) = PRESSURE_ERROR_MAX(:)
      REAL_BUFFER_2(3:5,:) = VELOCITY_ERROR_MAX_LOC(1:3,:)
      REAL_BUFFER_2(6:8,:) = PRESSURE_ERROR_MAX_LOC(1:3,:)
      CALL MPI_ALLGATHERV(REAL_BUFFER_2(1,DISPLS(MYID)+1),COUNTS_TEN(MYID),MPI_DOUBLE_PRECISION, &
                          REAL_BUFFER_3,COUNTS_TEN,DISPLS_TEN,MPI_DOUBLE_PRECISION,MPI_COMM_WORLD,IERR)
      VELOCITY_ERROR_MAX(:) = REAL_BUFFER_3(1,:)
      PRESSURE_ERROR_MAX(:) = REAL_BUFFER_3(2,:)
      VELOCITY_ERROR_MAX_LOC(1:3,:) = INT(REAL_BUFFER_3(3:5,:))
      PRESSURE_ERROR_MAX_LOC(1:3,:) = INT(REAL_BUFFER_3(6:8,:))
      T_USED(11)=T_USED(11) + CURRENT_TIME() - TNOW
   ENDIF

   IF (MYID==0 .AND. VELOCITY_ERROR_FILE .AND. .NOT.ALL(EVACUATION_ONLY)) THEN
      NM_MAX_V = MAXLOC(VELOCITY_ERROR_MAX,DIM=1)
      NM_MAX_P = MAXLOC(PRESSURE_ERROR_MAX,DIM=1)
      WRITE(LU_VELOCITY_ERROR,'(7(I7,A),E16.8,A,4(I7,A),E16.8)') ICYC,',',PRESSURE_ITERATIONS,',',TOTAL_PRESSURE_ITERATIONS,',',&
         NM_MAX_V,',',VELOCITY_ERROR_MAX_LOC(1,NM_MAX_V),',',VELOCITY_ERROR_MAX_LOC(2,NM_MAX_V),',',&
         VELOCITY_ERROR_MAX_LOC(3,NM_MAX_V),',',MAXVAL(VELOCITY_ERROR_MAX),',',&
         NM_MAX_P,',',PRESSURE_ERROR_MAX_LOC(1,NM_MAX_P),',',PRESSURE_ERROR_MAX_LOC(2,NM_MAX_P),',',&
         PRESSURE_ERROR_MAX_LOC(3,NM_MAX_P),',',MAXVAL(PRESSURE_ERROR_MAX)
   ENDIF

   ! If the VELOCITY_TOLERANCE is satisfied or max/min iterations are hit, exit the loop.

   IF (MAXVAL(PRESSURE_ERROR_MAX)<PRESSURE_TOLERANCE) ITERATE_BAROCLINIC_TERM = .FALSE.

   IF ((MAXVAL(PRESSURE_ERROR_MAX)<PRESSURE_TOLERANCE .AND. &
        MAXVAL(VELOCITY_ERROR_MAX)<VELOCITY_TOLERANCE) .OR. PRESSURE_ITERATIONS>=MAX_PRESSURE_ITERATIONS) &
      EXIT PRESSURE_ITERATION_LOOP

   ! Exit the iteration loop if satisfactory progress is not achieved

   IF (SUSPEND_PRESSURE_ITERATIONS .AND. ICYC>10) THEN
      IF (PRESSURE_ITERATIONS>3 .AND.  &
         MAXVAL(VELOCITY_ERROR_MAX)>ITERATION_SUSPEND_FACTOR*VELOCITY_ERROR_MAX_OLD .AND. &
         MAXVAL(PRESSURE_ERROR_MAX)>ITERATION_SUSPEND_FACTOR*PRESSURE_ERROR_MAX_OLD) EXIT PRESSURE_ITERATION_LOOP
      VELOCITY_ERROR_MAX_OLD = MAXVAL(VELOCITY_ERROR_MAX)
      PRESSURE_ERROR_MAX_OLD = MAXVAL(PRESSURE_ERROR_MAX)
   ENDIF

ENDDO PRESSURE_ITERATION_LOOP

END SUBROUTINE PRESSURE_ITERATION_SCHEME


SUBROUTINE CALCULATE_RTE_SOURCE_CORRECTION_FACTOR

! This routine computes a running average of the source correction factor for the radiative transport scheme.

REAL(EB), PARAMETER :: WGT=0.5_EB
REAL(EB) :: RAD_Q_SUM_ALL,KFST4_SUM_ALL,TNOW

TNOW = CURRENT_TIME()

! Sum up the components of the corrective factor from all the meshes.

IF (N_MPI_PROCESSES>1) THEN
   CALL MPI_ALLREDUCE(RAD_Q_SUM,RAD_Q_SUM_ALL,1,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
   CALL MPI_ALLREDUCE(KFST4_SUM,KFST4_SUM_ALL,1,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
ELSE
   RAD_Q_SUM_ALL = RAD_Q_SUM
   KFST4_SUM_ALL = KFST4_SUM
ENDIF

! Compute the corrective factor for the RTE. Note that the max value of 100 is arbitrary.

IF (KFST4_SUM_ALL>TWO_EPSILON_EB) &
   RTE_SOURCE_CORRECTION_FACTOR = WGT*RTE_SOURCE_CORRECTION_FACTOR + (1._EB-WGT)*MIN(C_MAX,MAX(C_MIN,RAD_Q_SUM_ALL/KFST4_SUM_ALL))

! Reset the components of the corrective factor to zero.

RAD_Q_SUM = 0._EB
KFST4_SUM = 0._EB

T_USED(11)=T_USED(11) + CURRENT_TIME() - TNOW
END SUBROUTINE CALCULATE_RTE_SOURCE_CORRECTION_FACTOR


SUBROUTINE GATHER_MEAN_WINDS

INTEGER :: K

! For the MEAN_FORCING functionality, determine the average velocity components as a function of height.
! U_MEAN_FORCING(K), V_MEAN_FORCING(K), W_MEAN_FORCING(K) are the average velocity components at height level K.
! Height level K spans the entire domain, not just a single mesh.

IF (MEAN_FORCING(1)) THEN
   IF (N_MPI_PROCESSES>1) THEN
      CALL MPI_ALLREDUCE(MPI_IN_PLACE,MEAN_FORCING_SUM_U_VOL,N_MEAN_FORCING_BINS,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
      CALL MPI_ALLREDUCE(MPI_IN_PLACE,MEAN_FORCING_SUM_VOL_X,N_MEAN_FORCING_BINS,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
   ENDIF
   IF (I_RAMP_U0_Z==0) THEN  ! if no vertical profile, sum over the entire domain, not just one height level
      MEAN_FORCING_SUM_VOL_X = SUM(MEAN_FORCING_SUM_VOL_X)
      MEAN_FORCING_SUM_U_VOL = SUM(MEAN_FORCING_SUM_U_VOL)
   ENDIF
   DO K=1,N_MEAN_FORCING_BINS
      IF (MEAN_FORCING_SUM_VOL_X(K)>TWO_EPSILON_EB) THEN
         U_MEAN_FORCING(K) = MEAN_FORCING_SUM_U_VOL(K)/MEAN_FORCING_SUM_VOL_X(K)
      ELSE
         U_MEAN_FORCING(K) = 0._EB
      ENDIF
   ENDDO
   MEAN_FORCING_SUM_VOL_X = 0._EB
   MEAN_FORCING_SUM_U_VOL = 0._EB
ENDIF

IF (MEAN_FORCING(2)) THEN
   IF (N_MPI_PROCESSES>1) THEN
      CALL MPI_ALLREDUCE(MPI_IN_PLACE,MEAN_FORCING_SUM_V_VOL,N_MEAN_FORCING_BINS,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
      CALL MPI_ALLREDUCE(MPI_IN_PLACE,MEAN_FORCING_SUM_VOL_Y,N_MEAN_FORCING_BINS,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
   ENDIF
   IF (I_RAMP_V0_Z==0) THEN  ! if no vertical profile, sum over the entire domain, not just one height level
      MEAN_FORCING_SUM_VOL_Y = SUM(MEAN_FORCING_SUM_VOL_Y)
      MEAN_FORCING_SUM_V_VOL = SUM(MEAN_FORCING_SUM_V_VOL)
   ENDIF
   DO K=1,N_MEAN_FORCING_BINS
      IF (MEAN_FORCING_SUM_VOL_Y(K)>TWO_EPSILON_EB) THEN
         V_MEAN_FORCING(K) = MEAN_FORCING_SUM_V_VOL(K)/MEAN_FORCING_SUM_VOL_Y(K)
      ELSE
         V_MEAN_FORCING(K) = 0._EB
      ENDIF
   ENDDO
   MEAN_FORCING_SUM_VOL_Y = 0._EB
   MEAN_FORCING_SUM_V_VOL = 0._EB
ENDIF

IF (MEAN_FORCING(3)) THEN
   IF (N_MPI_PROCESSES>1) THEN
      CALL MPI_ALLREDUCE(MPI_IN_PLACE,MEAN_FORCING_SUM_W_VOL,N_MEAN_FORCING_BINS,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
      CALL MPI_ALLREDUCE(MPI_IN_PLACE,MEAN_FORCING_SUM_VOL_Z,N_MEAN_FORCING_BINS,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
   ENDIF
   IF (I_RAMP_W0_Z==0) THEN  ! if no vertical profile, sum over the entire domain, not just one height level
      MEAN_FORCING_SUM_VOL_Z = SUM(MEAN_FORCING_SUM_VOL_Z)
      MEAN_FORCING_SUM_W_VOL = SUM(MEAN_FORCING_SUM_W_VOL)
   ENDIF
   DO K=1,N_MEAN_FORCING_BINS
      IF (MEAN_FORCING_SUM_VOL_Z(K)>TWO_EPSILON_EB) THEN
         W_MEAN_FORCING(K) = MEAN_FORCING_SUM_W_VOL(K)/MEAN_FORCING_SUM_VOL_Z(K)
      ELSE
         W_MEAN_FORCING(K) = 0._EB
      ENDIF
   ENDDO
   MEAN_FORCING_SUM_VOL_Z = 0._EB
   MEAN_FORCING_SUM_W_VOL = 0._EB
ENDIF

END SUBROUTINE GATHER_MEAN_WINDS


SUBROUTINE WRITE_CFL_FILE

! This routine gathers all the CFL values and mesh indices to node 0, which then
! writes out the max value and mesh and indices of the max value.

REAL(EB), DIMENSION(NMESHES) :: CFL_VALUES,VN_VALUES
INTEGER :: NM_CFL_MAX,NM_VN_MAX

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   REAL_BUFFER_13(1,NM) = MESHES(NM)%CFL
   REAL_BUFFER_13(2,NM) = MESHES(NM)%ICFL
   REAL_BUFFER_13(3,NM) = MESHES(NM)%JCFL
   REAL_BUFFER_13(4,NM) = MESHES(NM)%KCFL
   REAL_BUFFER_13(5,NM) = MESHES(NM)%VN
   REAL_BUFFER_13(6,NM) = MESHES(NM)%I_VN
   REAL_BUFFER_13(7,NM) = MESHES(NM)%J_VN
   REAL_BUFFER_13(8,NM) = MESHES(NM)%K_VN
   REAL_BUFFER_13(9,NM) = MESHES(NM)%US(MESHES(NM)%ICFL-1,MESHES(NM)%JCFL  ,MESHES(NM)%KCFL  )
   REAL_BUFFER_13(10,NM)= MESHES(NM)%US(MESHES(NM)%ICFL  ,MESHES(NM)%JCFL  ,MESHES(NM)%KCFL  )
   REAL_BUFFER_13(11,NM)= MESHES(NM)%VS(MESHES(NM)%ICFL  ,MESHES(NM)%JCFL-1,MESHES(NM)%KCFL  )
   REAL_BUFFER_13(12,NM)= MESHES(NM)%VS(MESHES(NM)%ICFL  ,MESHES(NM)%JCFL  ,MESHES(NM)%KCFL  )
   REAL_BUFFER_13(13,NM)= MESHES(NM)%WS(MESHES(NM)%ICFL  ,MESHES(NM)%JCFL  ,MESHES(NM)%KCFL-1)
   REAL_BUFFER_13(14,NM)= MESHES(NM)%WS(MESHES(NM)%ICFL  ,MESHES(NM)%JCFL  ,MESHES(NM)%KCFL  )
   REAL_BUFFER_13(15,NM)= MESHES(NM)%DS(MESHES(NM)%ICFL  ,MESHES(NM)%JCFL  ,MESHES(NM)%KCFL  )
   REAL_BUFFER_13(16,NM)= MESHES(NM)%MU(MESHES(NM)%ICFL  ,MESHES(NM)%JCFL  ,MESHES(NM)%KCFL  )
   REAL_BUFFER_13(17,NM)= MESHES(NM)%Q( MESHES(NM)%ICFL  ,MESHES(NM)%JCFL  ,MESHES(NM)%KCFL  )*0.001_EB
ENDDO

CALL MPI_GATHERV(REAL_BUFFER_13(1,DISPLS(MYID)+1),COUNTS_TWENTY(MYID),MPI_DOUBLE_PRECISION, &
                 REAL_BUFFER_14,COUNTS_TWENTY,DISPLS_TWENTY,MPI_DOUBLE_PRECISION,0,MPI_COMM_WORLD,IERR)

IF (MYID==0 .AND. .NOT.ALL(EVACUATION_ONLY)) THEN
   CFL_VALUES(:) = REAL_BUFFER_14(1,:)
   VN_VALUES(:)  = REAL_BUFFER_14(5,:)
   NM_CFL_MAX  = MAXLOC(CFL_VALUES,DIM=1)
   NM_VN_MAX   = MAXLOC(VN_VALUES,DIM=1)
   WRITE(LU_CFL,'(I7,A,2(ES12.4,A),F6.3,A,4(I4,A),6(F7.3,A),3(ES12.4,A),F6.3,4(A,I4))') ICYC,',',T,',',DT,',',&
         MAXVAL(CFL_VALUES),',',NM_CFL_MAX,',',&
         NINT(REAL_BUFFER_14(2,NM_CFL_MAX)),',',NINT(REAL_BUFFER_14(3,NM_CFL_MAX)),',',NINT(REAL_BUFFER_14(4,NM_CFL_MAX)),',',&
         REAL_BUFFER_14( 9,NM_CFL_MAX),',',REAL_BUFFER_14(10,NM_CFL_MAX),',',REAL_BUFFER_14(11,NM_CFL_MAX),',',&
         REAL_BUFFER_14(12,NM_CFL_MAX),',',REAL_BUFFER_14(13,NM_CFL_MAX),',',REAL_BUFFER_14(14,NM_CFL_MAX),',',&
         REAL_BUFFER_14(15,NM_CFL_MAX),',',REAL_BUFFER_14(16,NM_CFL_MAX),',',REAL_BUFFER_14(17,NM_CFL_MAX),',',&
         MAXVAL(VN_VALUES),',',NM_VN_MAX,',',&
         NINT(REAL_BUFFER_14(6,NM_VN_MAX)),',',NINT(REAL_BUFFER_14(7,NM_VN_MAX)),',',NINT(REAL_BUFFER_14(8,NM_VN_MAX))
ENDIF

END SUBROUTINE WRITE_CFL_FILE


SUBROUTINE STOP_CHECK(END_CODE)

INTEGER, INTENT(IN) :: END_CODE
REAL(EB) :: TNOW

! Make sure that all MPI processes have the same STOP_STATUS

IF (N_MPI_PROCESSES>1) THEN
   TNOW = CURRENT_TIME()
   CALL MPI_ALLREDUCE(MPI_IN_PLACE,STOP_STATUS,INTEGER_ONE,MPI_INTEGER,MPI_MAX,MPI_COMM_WORLD,IERR)
   T_USED(11)=T_USED(11) + CURRENT_TIME() - TNOW
ENDIF

SELECT CASE(STOP_STATUS)
   CASE(NO_STOP)
      RETURN
   CASE(USER_STOP)
      DIAGNOSTICS = .TRUE.
      IF (STOP_AT_ITER==0 .AND. .NOT.ALL(RADIATION_COMPLETED)) RETURN
END SELECT

IF (END_CODE==1) CALL END_FDS

END SUBROUTINE STOP_CHECK


SUBROUTINE END_FDS

! End the calculation gracefully, even if there is an error

CHARACTER(255) :: MESSAGE

IF (STOP_STATUS==NO_STOP .OR. STOP_STATUS==USER_STOP) CALL DUMP_TIMERS

IF (VERBOSE) WRITE(LU_ERR,'(A,I6,A)') ' MPI process ',MYID,' has completed'

IF (MYID==0) THEN

   ! Print out device activation times to the .out file

   CALL TIMINGS

   ! Print out stop status to .err and .out files

   SELECT CASE(STOP_STATUS)
      CASE(NO_STOP)
         WRITE(MESSAGE,'(A)') 'STOP: FDS completed successfully'
         IF (STATUS_FILES) CLOSE(LU_NOTREADY,STATUS='DELETE')
      CASE(INSTABILITY_STOP)
         WRITE(MESSAGE,'(A)') 'ERROR: Numerical Instability - FDS stopped'
      CASE(USER_STOP)
         WRITE(MESSAGE,'(A)') 'STOP: FDS stopped by user'
      CASE(SETUP_STOP)
         WRITE(MESSAGE,'(A)') 'ERROR: FDS was improperly set-up - FDS stopped'
      CASE(SETUP_ONLY_STOP)
         WRITE(MESSAGE,'(A)') 'STOP: Set-up only'
      CASE(CTRL_STOP)
         WRITE(MESSAGE,'(A)') 'STOP: FDS was stopped by KILL control function'
      CASE(TGA_ANALYSIS_STOP)
         WRITE(MESSAGE,'(A)') 'STOP: TGA analysis only'
      CASE(LEVELSET_STOP)
         WRITE(MESSAGE,'(A)') 'STOP: Level set analysis only'
      CASE(REALIZABILITY_STOP)
         WRITE(MESSAGE,'(A)') 'ERROR: Unrealizable mass density - FDS stopped'
      CASE DEFAULT
         WRITE(MESSAGE,'(A)') 'null'
   END SELECT

   IF (MESSAGE/='null') THEN
      WRITE(LU_ERR,'(/A,A,A,A)') TRIM(MESSAGE),' (CHID: ',TRIM(CHID),')'
      IF (OUT_FILE_OPENED) WRITE(LU_OUTPUT,'(/A,A,A,A)') TRIM(MESSAGE),' (CHID: ',TRIM(CHID),')'
   ENDIF

ENDIF

! Shutdown MPI

CALL MPI_FINALIZE(IERR)

! Shutdown FDS

STOP

END SUBROUTINE END_FDS


SUBROUTINE EXCHANGE_DIVERGENCE_INFO

! Exchange information mesh to mesh needed for divergence integrals
! First, sum DSUM, PSUM and USUM over all meshes controlled by the active process, then reduce over all processes

INTEGER :: IPZ,IOPZ,IOPZ2
REAL(EB) :: TNOW

TNOW = CURRENT_TIME()

CONNECTED_ZONES_LOCAL = .FALSE.

DO IPZ=1,N_ZONE
   DSUM_ALL_LOCAL(IPZ) = 0._EB
   PSUM_ALL_LOCAL(IPZ) = 0._EB
   USUM_ALL_LOCAL(IPZ) = 0._EB
   IF(P_ZONE(IPZ)%EVACUATION) CYCLE
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF(EVACUATION_ONLY(NM)) CYCLE
      DSUM_ALL_LOCAL(IPZ) = DSUM_ALL_LOCAL(IPZ) + DSUM(IPZ,NM)
      PSUM_ALL_LOCAL(IPZ) = PSUM_ALL_LOCAL(IPZ) + PSUM(IPZ,NM)
      USUM_ALL_LOCAL(IPZ) = USUM_ALL_LOCAL(IPZ) + USUM(IPZ,NM)
      DO IOPZ=0,N_ZONE
         IF (CONNECTED_ZONES(IPZ,IOPZ,NM)) CONNECTED_ZONES_LOCAL(IPZ,IOPZ) = .TRUE.
      ENDDO
   ENDDO
ENDDO

IF (N_MPI_PROCESSES>1) THEN
   CALL MPI_ALLREDUCE(DSUM_ALL_LOCAL(1),DSUM_ALL(1),N_ZONE,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
   CALL MPI_ALLREDUCE(PSUM_ALL_LOCAL(1),PSUM_ALL(1),N_ZONE,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
   CALL MPI_ALLREDUCE(USUM_ALL_LOCAL(1),USUM_ALL(1),N_ZONE,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,IERR)
   CALL MPI_ALLREDUCE(CONNECTED_ZONES_LOCAL(0,0),CONNECTED_ZONES_GLOBAL(0,0),(N_ZONE+1)**2,MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,IERR)
ELSE
   DSUM_ALL = DSUM_ALL_LOCAL
   PSUM_ALL = PSUM_ALL_LOCAL
   USUM_ALL = USUM_ALL_LOCAL
   CONNECTED_ZONES_GLOBAL = CONNECTED_ZONES_LOCAL
ENDIF

DO IPZ=1,N_ZONE
   IF(P_ZONE(IPZ)%EVACUATION) CYCLE
   DO NM=1,NMESHES
      IF(EVACUATION_ONLY(NM)) CYCLE
      DSUM(IPZ,NM) = DSUM_ALL(IPZ)
      PSUM(IPZ,NM) = PSUM_ALL(IPZ)
      USUM(IPZ,NM) = USUM_ALL(IPZ)
      CONNECTED_ZONES(IPZ,:,NM) = CONNECTED_ZONES_GLOBAL(IPZ,:)
   ENDDO
ENDDO

! Connect zones to others which are not directly connected

DO NM=1,NMESHES
   IF(EVACUATION_ONLY(NM)) CYCLE
   DO IPZ=1,N_ZONE
      IF(P_ZONE(IPZ)%EVACUATION) CYCLE
      DO IOPZ=1,N_ZONE
         IF(P_ZONE(IOPZ)%EVACUATION) CYCLE
         IF (IOPZ==IPZ) CYCLE
         IF (CONNECTED_ZONES(IPZ,IOPZ,NM)) THEN
            DO IOPZ2=0,N_ZONE
               IF (IOPZ==IOPZ2) CYCLE
               IF (CONNECTED_ZONES(IOPZ,IOPZ2,NM)) CONNECTED_ZONES(IPZ,IOPZ2,NM) = .TRUE.
               IF (CONNECTED_ZONES(IOPZ,IOPZ2,NM)) CONNECTED_ZONES(IOPZ2,IPZ,NM) = .TRUE.
            ENDDO
         ENDIF
      ENDDO
   ENDDO
ENDDO

T_USED(11)=T_USED(11) + CURRENT_TIME() - TNOW
END SUBROUTINE EXCHANGE_DIVERGENCE_INFO


SUBROUTINE INITIALIZE_MESH_EXCHANGE_1(NM)

! Create arrays by which info is to be exchanged across meshes

INTEGER :: IMIN,IMAX,JMIN,JMAX,KMIN,KMAX,NOM,IOR,IW,N,N_STORAGE_SLOTS,IIO,JJO,KKO,NIC_R,II,JJ,KK
INTEGER, INTENT(IN) :: NM
TYPE (MESH_TYPE), POINTER :: M2,M
TYPE (OMESH_TYPE), POINTER :: OM
TYPE (EXTERNAL_WALL_TYPE), POINTER :: EWC
TYPE (WALL_TYPE), POINTER :: WC
TYPE (LAGRANGIAN_PARTICLE_CLASS_TYPE), POINTER :: LPC
LOGICAL :: FOUND

M=>MESHES(NM)

NOT_EVACUATION_MESH_IF: IF (.NOT.EVACUATION_ONLY(NM)) THEN

ALLOCATE(MESHES(NM)%OMESH(NMESHES))

ALLOCATE(M%CONNECTED_MESH(NMESHES)) ; M%CONNECTED_MESH = .FALSE.
ALLOCATE(M%OMESH(NM)%BOUNDARY_TYPE(0:M%N_EXTERNAL_WALL_CELLS))
M%OMESH(NM)%BOUNDARY_TYPE(0) = 0
DO IW=1,M%N_EXTERNAL_WALL_CELLS
   M%OMESH(NM)%BOUNDARY_TYPE(IW) = M%WALL(IW)%BOUNDARY_TYPE
ENDDO

END IF NOT_EVACUATION_MESH_IF

OTHER_MESH_LOOP: DO NOM=1,NMESHES

   IF (EVACUATION_ONLY(NM)) THEN
      IF (EMESH_INDEX(NM)>0 .AND. .NOT.EVACUATION_ONLY(NOM)) N_COMMUNICATIONS = N_COMMUNICATIONS + 1
      CYCLE OTHER_MESH_LOOP
   ENDIF
   IF (EVACUATION_ONLY(NOM)) THEN
      IF (EMESH_INDEX(NOM)>0 .AND. .NOT.EVACUATION_ONLY(NM)) N_COMMUNICATIONS = N_COMMUNICATIONS + 1
      CYCLE OTHER_MESH_LOOP
   ENDIF

   OM => M%OMESH(NOM)
   M2 => MESHES(NOM)

   IMIN=0
   IMAX=M2%IBP1
   JMIN=0
   JMAX=M2%JBP1
   KMIN=0
   KMAX=M2%KBP1

   ! DEFINITION NIC_R: (Number of Interpolated Cells -- Receiving) Number of cells in mesh NOM that abut mesh NM.
   ! DEFINITION IIO_R: Array of length NIC_R of I indices of the abutting (outside) cells
   ! DEFINITION JJO_R: Array of length NIC_R of J indices of the abutting (outside) cells
   ! DEFINITION KKO_R: Array of length NIC_R of K indices of the abutting (outside) cells
   ! DEFINITION IOR_R: Array of length NIC_R of orientation of the external boundary cell
   ! DEFINITION NIC_MIN: For external wall cell IW of mesh NM, the indices of abutting cells start with NIC_MIN and end with NIC_MAX
   ! DEFINITION NIC_MAX: For external wall cell IW of mesh NM, the indices of abutting cells start with NIC_MIN and end with NIC_MAX

   OM%NIC_R = 0
   FOUND = .FALSE.

   SEARCH_LOOP: DO IW=1,M%N_EXTERNAL_WALL_CELLS

      EWC => M%EXTERNAL_WALL(IW)
      IF (EWC%NOM/=NOM) CYCLE SEARCH_LOOP
      WC => M%WALL(IW)
      II = WC%ONE_D%II
      JJ = WC%ONE_D%JJ
      KK = WC%ONE_D%KK
      EWC%NIC_MIN = OM%NIC_R + 1
      OM%NIC_R = OM%NIC_R + (EWC%IIO_MAX-EWC%IIO_MIN+1)*(EWC%JJO_MAX-EWC%JJO_MIN+1)*(EWC%KKO_MAX-EWC%KKO_MIN+1)
      EWC%NIC_MAX = OM%NIC_R
      FOUND = .TRUE.
      M%CONNECTED_MESH(NOM) = .TRUE.
      IOR = M%WALL(IW)%ONE_D%IOR
      SELECT CASE(IOR)
         CASE( 1)
            IMIN=MAX(IMIN,EWC%IIO_MIN-1)
         CASE(-1)
            IMAX=MIN(IMAX,EWC%IIO_MAX+1)
         CASE( 2)
            JMIN=MAX(JMIN,EWC%JJO_MIN-1)
         CASE(-2)
            JMAX=MIN(JMAX,EWC%JJO_MAX+1)
         CASE( 3)
            KMIN=MAX(KMIN,EWC%KKO_MIN-1)
         CASE(-3)
            KMAX=MIN(KMAX,EWC%KKO_MAX+1)
      END SELECT

      SELECT CASE(ABS(IOR))
         CASE(1)
            EWC%AREA_RATIO = M%DY(JJ)*M%DZ(KK)/((M2%Y(EWC%JJO_MAX)-M2%Y(EWC%JJO_MIN-1))*(M2%Z(EWC%KKO_MAX)-M2%Z(EWC%KKO_MIN-1)))
         CASE(2)
            EWC%AREA_RATIO = M%DX(II)*M%DZ(KK)/((M2%X(EWC%IIO_MAX)-M2%X(EWC%IIO_MIN-1))*(M2%Z(EWC%KKO_MAX)-M2%Z(EWC%KKO_MIN-1)))
         CASE(3)
            EWC%AREA_RATIO = M%DX(II)*M%DY(JJ)/((M2%X(EWC%IIO_MAX)-M2%X(EWC%IIO_MIN-1))*(M2%Y(EWC%JJO_MAX)-M2%Y(EWC%JJO_MIN-1)))
      END SELECT
   ENDDO SEARCH_LOOP

   ! Allocate arrays to hold indices of arrays for MPI exchanges

   IF (OM%NIC_R>0) THEN
      ALLOCATE(OM%IIO_R(OM%NIC_R))
      ALLOCATE(OM%JJO_R(OM%NIC_R))
      ALLOCATE(OM%KKO_R(OM%NIC_R))
      ALLOCATE(OM%IOR_R(OM%NIC_R))
      NIC_R = 0
      INDEX_LOOP: DO IW=1,M%N_EXTERNAL_WALL_CELLS
         EWC => M%EXTERNAL_WALL(IW)
         IF (EWC%NOM/=NOM) CYCLE INDEX_LOOP
         DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
            DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
               DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
                  NIC_R = NIC_R + 1
                  IOR = M%WALL(IW)%ONE_D%IOR
                  OM%IIO_R(NIC_R) = IIO
                  OM%JJO_R(NIC_R) = JJO
                  OM%KKO_R(NIC_R) = KKO
                  OM%IOR_R(NIC_R) = IOR
               ENDDO
            ENDDO
         ENDDO
      ENDDO INDEX_LOOP

   ENDIF

   ! For PERIODIC boundaries with 1 or 2 meshes, we must revert to allocating whole copies of OMESH

   IF (IMIN>IMAX) THEN; IMIN=0; IMAX=M2%IBP1; ENDIF
   IF (JMIN>JMAX) THEN; JMIN=0; JMAX=M2%JBP1; ENDIF
   IF (KMIN>KMAX) THEN; KMIN=0; KMAX=M2%KBP1; ENDIF

   ! Embedded meshes. This is the case where mesh NOM is completely inside mesh NM. Mesh NM cannot "see" mesh NOM because mesh NOM
   ! is not connected at the external boundary of mesh NM. The variable CONNECTED_MESH is needed to save this information.

   IF ( NM/=NOM .AND. M2%XS>=M%XS .AND. M2%XF<=M%XF .AND. M2%YS>=M%YS .AND. M2%YF<=M%YF .AND. M2%ZS>=M%ZS .AND. M2%ZF<=M%ZF ) THEN
      FOUND = .TRUE.
      M%CONNECTED_MESH(NOM) = .TRUE.
   ENDIF

   ! Exit the other mesh loop if no neighboring meshes found

   IF (.NOT.FOUND) CYCLE OTHER_MESH_LOOP

   ! Tally the number of communications for this process

   N_COMMUNICATIONS = N_COMMUNICATIONS + 1

   ! Save the dimensions of the volume of cells from mesh NOM whose data is received by mesh NM
   ! DEFINITION I_MIN_R: Starting I index of cell block of mesh NOM whose info is to be received by mesh NM in MPI exchanges.
   ! DEFINITION I_MAX_R: Ending   I index of cell block of mesh NOM whose info is to be received by mesh NM in MPI exchanges.
   ! DEFINITION J_MIN_R: Starting J index of cell block of mesh NOM whose info is to be received by mesh NM in MPI exchanges.
   ! DEFINITION J_MAX_R: Ending   J index of cell block of mesh NOM whose info is to be received by mesh NM in MPI exchanges.
   ! DEFINITION K_MIN_R: Starting K index of cell block of mesh NOM whose info is to be received by mesh NM in MPI exchanges.
   ! DEFINITION K_MAX_R: Ending   K index of cell block of mesh NOM whose info is to be received by mesh NM in MPI exchanges.

   OM%I_MIN_R = IMIN
   OM%I_MAX_R = IMAX
   OM%J_MIN_R = JMIN
   OM%J_MAX_R = JMAX
   OM%K_MIN_R = KMIN
   OM%K_MAX_R = KMAX

   ! Allocate the arrays that hold information about the other meshes (OMESH)

   ALLOCATE(OM% RHO(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(OM%RHOS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   OM%RHO  = RHOA
   OM%RHOS = RHOA
   ALLOCATE(OM% D(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(OM%DS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   OM%D  = 0._EB
   OM%DS = 0._EB
   ALLOCATE(OM%  MU(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   OM%MU = 0._EB
   ALLOCATE(OM%    H(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(OM%   HS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   OM%H  = 0._EB
   OM%HS = 0._EB
   ALLOCATE(OM%   U(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(OM%  US(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   OM%U  = U0
   OM%US = U0
   ALLOCATE(OM%   V(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(OM%  VS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   OM%V  = V0
   OM%VS = V0
   ALLOCATE(OM%   W(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(OM%  WS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   OM%W  = W0
   OM%WS = W0
   ALLOCATE(OM% FVX(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(OM% FVY(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(OM% FVZ(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   OM%FVX = 0._EB
   OM%FVY = 0._EB
   OM%FVZ = 0._EB
   ALLOCATE(OM%KRES(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   OM%KRES = 0._EB
   ALLOCATE(OM%Q(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   OM%Q = 0._EB

   ALLOCATE(OM%  ZZ(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX,N_TOTAL_SCALARS))
   ALLOCATE(OM% ZZS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX,N_TOTAL_SCALARS))
   DO N=1,N_TRACKED_SPECIES
      OM%ZZ(:,:,:,N)  = SPECIES_MIXTURE(N)%ZZ0
      OM%ZZS(:,:,:,N) = SPECIES_MIXTURE(N)%ZZ0
   ENDDO
   DO N=N_TRACKED_SPECIES+1,N_TOTAL_SCALARS
      OM%ZZ(:,:,:,N)  = INITIAL_UNMIXED_FRACTION
      OM%ZZS(:,:,:,N) = INITIAL_UNMIXED_FRACTION
   ENDDO

   IF (SOLID_HT3D) THEN
      ALLOCATE(OM%TMP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
      OM%TMP = TMPA
   ENDIF

   IF (LEVEL_SET_MODE>0 .OR. TERRAIN_CASE) THEN
      ALLOCATE(OM%PHI_LS(IMIN:IMAX,JMIN:JMAX))  ; OM%PHI_LS   = -1._EB
      ALLOCATE(OM%PHI1_LS(IMIN:IMAX,JMIN:JMAX)) ; OM%PHI1_LS  = -1._EB
      ALLOCATE(OM%U_LS(IMIN:IMAX,JMIN:JMAX))    ; OM%U_LS     =  0._EB
      ALLOCATE(OM%V_LS(IMIN:IMAX,JMIN:JMAX))    ; OM%V_LS     =  0._EB
      ALLOCATE(OM%Z_LS(IMIN:IMAX,JMIN:JMAX))    ; OM%Z_LS     =  0._EB
   ENDIF

   ! Wall arrays

   IF (.NOT.ALLOCATED(OM%BOUNDARY_TYPE)) ALLOCATE(OM%BOUNDARY_TYPE(0:M2%N_EXTERNAL_WALL_CELLS))
   OM%BOUNDARY_TYPE(0)=0

   ! Particle and PARTICLE Orphan Arrays

   IF (OMESH_PARTICLES) THEN
      ALLOCATE(OM%N_PART_ORPHANS(N_LAGRANGIAN_CLASSES))
      ALLOCATE(OM%N_PART_ADOPT(N_LAGRANGIAN_CLASSES))
      OM%N_PART_ORPHANS = 0
      OM%N_PART_ADOPT   = 0
      ALLOCATE(OM%ORPHAN_PARTICLE_STORAGE(N_LAGRANGIAN_CLASSES))
      ALLOCATE(OM%ADOPT_PARTICLE_STORAGE(N_LAGRANGIAN_CLASSES))
      DO N=1,N_LAGRANGIAN_CLASSES
         LPC => LAGRANGIAN_PARTICLE_CLASS(N)
         N_STORAGE_SLOTS = 1000
         OM%ORPHAN_PARTICLE_STORAGE(N)%N_STORAGE_SLOTS = N_STORAGE_SLOTS
         OM%ADOPT_PARTICLE_STORAGE(N)%N_STORAGE_SLOTS = N_STORAGE_SLOTS
         ALLOCATE(OM%ORPHAN_PARTICLE_STORAGE(N)%REALS(LPC%N_STORAGE_REALS,N_STORAGE_SLOTS))
         ALLOCATE(OM%ORPHAN_PARTICLE_STORAGE(N)%INTEGERS(LPC%N_STORAGE_INTEGERS,N_STORAGE_SLOTS))
         ALLOCATE(OM%ORPHAN_PARTICLE_STORAGE(N)%LOGICALS(LPC%N_STORAGE_LOGICALS,N_STORAGE_SLOTS))
         ALLOCATE(OM%ADOPT_PARTICLE_STORAGE(N)%REALS(LPC%N_STORAGE_REALS,N_STORAGE_SLOTS))
         ALLOCATE(OM%ADOPT_PARTICLE_STORAGE(N)%INTEGERS(LPC%N_STORAGE_INTEGERS,N_STORAGE_SLOTS))
         ALLOCATE(OM%ADOPT_PARTICLE_STORAGE(N)%LOGICALS(LPC%N_STORAGE_LOGICALS,N_STORAGE_SLOTS))
      ENDDO
   ENDIF

ENDDO OTHER_MESH_LOOP

END SUBROUTINE INITIALIZE_MESH_EXCHANGE_1


SUBROUTINE INITIALIZE_MESH_EXCHANGE_2(NM)

! Create arrays by which info is to exchanged across meshes. In this routine, allocate arrays that involve NIC_R and NIC_S arrays.

INTEGER :: NOM
INTEGER, INTENT(IN) :: NM
TYPE (MESH_TYPE), POINTER :: M

IF (EVACUATION_ONLY(NM)) RETURN

M=>MESHES(NM)

! Allocate arrays to send (IL_S) and receive (IL_R) the radiation intensity (IL) at interpolated boundaries.
! MESHES(NM)%OMESH(NOM)%IL_S are the intensities in mesh NM that are just outside the boundary of mesh NOM. IL_S is populated
! in radi.f90 and then sent to MESHES(NOM)%OMESH(NM)%IL_R in MESH_EXCHANGE. IL_R holds the intensities until they are
! transferred to the ghost cells of MESHES(NOM)%IL in radi.f90. The IL_S and IL_R arrays are indexed by NIC_S and NIC_R.

DO NOM=1,NMESHES
   IF (M%OMESH(NOM)%NIC_S>0) THEN
      ALLOCATE(M%OMESH(NOM)%IL_S(M%OMESH(NOM)%NIC_S,NUMBER_RADIATION_ANGLES,NUMBER_SPECTRAL_BANDS))
      M%OMESH(NOM)%IL_S = RPI*SIGMA*TMPA4
    ENDIF
   IF (M%OMESH(NOM)%NIC_R>0) THEN
      ALLOCATE(M%OMESH(NOM)%IL_R(M%OMESH(NOM)%NIC_R,NUMBER_RADIATION_ANGLES,NUMBER_SPECTRAL_BANDS))
      M%OMESH(NOM)%IL_R = RPI*SIGMA*TMPA4
   ENDIF
ENDDO

END SUBROUTINE INITIALIZE_MESH_EXCHANGE_2


SUBROUTINE INITIALIZE_BACK_WALL_EXCHANGE

! Bordering meshes tell their neighbors how many exposed back wall cells they expect information for.

CALL POST_RECEIVES(8)
CALL MESH_EXCHANGE(8)

! DEFINITION MESHES(NM)%OMESH(NOM)%N_WALL_CELLS_SEND
! Number of wall cells in Mesh NM for which information must be sent to Mesh NOM.
! DEFINITION MESHES(NM)%OMESH(NOM)%WALL_CELL_INDICES_SEND
! Indices of the wall cells in Mesh NM for which information needs to be sent to Mesh NOM.

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=1,NMESHES
      M3 => MESHES(NM)%OMESH(NOM)
      IF (M3%N_WALL_CELLS_SEND>0) ALLOCATE(M3%WALL_CELL_INDICES_SEND(M3%N_WALL_CELLS_SEND))
   ENDDO
ENDDO

! Mesh NM sends MESHES(NM)%OMESH(NOM)%EXPOSED_WALL_CELL_BACK_INDICES to Mesh NOM where it is received into
! MESHES(NOM)%OMESH(NM)%WALL_CELL_INDICES_SEND

CALL POST_RECEIVES(9)
CALL MESH_EXCHANGE(9)

! Set up arrays to send and receive exposed back wall cell information.

MESH_LOOP_1: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (EVACUATION_ONLY(NM)) CYCLE MESH_LOOP_1
   M => MESHES(NM)
   MESH_LOOP_2: DO NOM=1,NMESHES
      IF (NM==NOM .OR. EVACUATION_ONLY(NOM)) CYCLE MESH_LOOP_2
      M3 => M%OMESH(NOM)
      IF (M3%N_WALL_CELLS_SEND>0) ALLOCATE(M3%REAL_SEND_PKG6(M3%N_WALL_CELLS_SEND*2))
      IF (M3%N_EXPOSED_WALL_CELLS>0) THEN
         ALLOCATE(M3%REAL_RECV_PKG6(M3%N_EXPOSED_WALL_CELLS*2))
         ALLOCATE(M3%EXPOSED_WALL(M3%N_EXPOSED_WALL_CELLS))
      ENDIF
   ENDDO MESH_LOOP_2
ENDDO MESH_LOOP_1

! Check to see if any process has an error. If so, stop the run.

CALL STOP_CHECK(1)

! Set up persistent SEND and RECV calls for BACK_WALL info

CALL POST_RECEIVES(10)
CALL MESH_EXCHANGE(10)

END SUBROUTINE INITIALIZE_BACK_WALL_EXCHANGE


SUBROUTINE POST_RECEIVES(CODE)

! Set up receive buffers for MPI calls.

INTEGER, INTENT(IN) :: CODE
INTEGER :: RNODE,SNODE,IJK_SIZE,N,N_STORAGE_SLOTS,NRA,NRA_MAX,LL,AIC
REAL(EB) :: TNOW
TYPE (LAGRANGIAN_PARTICLE_CLASS_TYPE), POINTER :: LPC

TNOW = CURRENT_TIME()

! Initialize the number of non-persistent send/receive requests.

N_REQ = 0

! Loop over all receive meshes (NM) and look for the send meshes (NOM).

MESH_LOOP: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   IF (EVACUATION_ONLY(NM)) CYCLE MESH_LOOP

   RNODE = PROCESS(NM)
   M => MESHES(NM)

   OTHER_MESH_LOOP: DO NOM=1,NMESHES

      M3=>MESHES(NM)%OMESH(NOM)
      IF (M3%NIC_S==0 .AND. M3%NIC_R==0) CYCLE OTHER_MESH_LOOP
      IF (EVACUATION_ONLY(NOM)) CYCLE OTHER_MESH_LOOP
      IF (CODE>0 .AND. (EVACUATION_SKIP(NOM).OR.EVACUATION_SKIP(NM))) CYCLE OTHER_MESH_LOOP

      SNODE = PROCESS(NOM)
      IF (RNODE==SNODE) CYCLE OTHER_MESH_LOOP

      M4=>MESHES(NOM)

      ! Set up receives for one-time exchanges or persistent send/receives.

      INITIALIZATION_IF: IF (CODE==0) THEN

         IF (.NOT.ALLOCATED(M4%CELL_INDEX))   ALLOCATE(M4%CELL_INDEX(0:M4%IBP1,0:M4%JBP1,0:M4%KBP1))
         IF (.NOT.ALLOCATED(M4%SOLID))        ALLOCATE(M4%SOLID(0:CELL_COUNT(NOM)))
         IF (.NOT.ALLOCATED(M4%WALL_INDEX))   ALLOCATE(M4%WALL_INDEX(0:CELL_COUNT(NOM),-3:3))
         IF (.NOT.ALLOCATED(M4%OBST_INDEX_C)) ALLOCATE(M4%OBST_INDEX_C(0:CELL_COUNT(NOM)))

         N_REQ = MIN(N_REQ+1,SIZE(REQ))
         CALL MPI_IRECV(M4%CELL_INDEX(0,0,0),SIZE(M4%CELL_INDEX),MPI_INTEGER,SNODE,NOM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
         N_REQ = MIN(N_REQ+1,SIZE(REQ))
         CALL MPI_IRECV(M4%SOLID(0),SIZE(M4%SOLID),MPI_INTEGER,SNODE,NOM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
         N_REQ = MIN(N_REQ+1,SIZE(REQ))
         CALL MPI_IRECV(M4%WALL_INDEX(0,-3),SIZE(M4%WALL_INDEX),MPI_INTEGER,SNODE,NOM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
         N_REQ = MIN(N_REQ+1,SIZE(REQ))
         CALL MPI_IRECV(M4%OBST_INDEX_C(0),SIZE(M4%OBST_INDEX_C),MPI_INTEGER,SNODE,NOM,MPI_COMM_WORLD,REQ(N_REQ),IERR)

         IJK_SIZE = (M3%I_MAX_R-M3%I_MIN_R+1)*(M3%J_MAX_R-M3%J_MIN_R+1)*(M3%K_MAX_R-M3%K_MIN_R+1)

         IF (M3%NIC_R>0) THEN

            ! Determine the maximum number of radiation angles that are to be received

            NRA_MAX = 0
            IF (RADIATION) THEN
               DO AIC=1,ANGLE_INCREMENT
                  DO LL=1,M3%NIC_R
                     NRA = 0
                     DO N=NUMBER_RADIATION_ANGLES-AIC+1,1,-ANGLE_INCREMENT
                        IF (DLN(M3%IOR_R(LL),N)>0._EB) NRA = NRA + 1
                     ENDDO
                     NRA_MAX = MAX(NRA_MAX,NRA)
                  ENDDO
               ENDDO
            ENDIF

            ! Allocate the 1-D arrays that hold the big mesh variables that are to be received

            ALLOCATE(M3%REAL_RECV_PKG1(M3%NIC_R*(6+2*N_TOTAL_SCALARS)))
            ALLOCATE(M3%REAL_RECV_PKG3(IJK_SIZE*4))
            ALLOCATE(M3%REAL_RECV_PKG5(NRA_MAX*NUMBER_SPECTRAL_BANDS*M3%NIC_R))
            ALLOCATE(M3%REAL_RECV_PKG7(M3%NIC_R*3))

            IF (SOLID_HT3D) ALLOCATE(M3%REAL_RECV_PKG4(M3%NIC_R*2))

            IF (LEVEL_SET_MODE>0 .OR. TERRAIN_CASE) ALLOCATE(M3%REAL_RECV_PKG14(4*M3%NIC_R))

         ENDIF

         ! Set up persistent receive requests

         IF (M3%NIC_R>0) THEN

            N_REQ1 = N_REQ1 + 1
            CALL MPI_RECV_INIT(M3%REAL_RECV_PKG1(1),SIZE(M3%REAL_RECV_PKG1),MPI_DOUBLE_PRECISION,SNODE,NOM,MPI_COMM_WORLD,&
                               REQ1(N_REQ1),IERR)

            IF (OMESH_PARTICLES) THEN
               N_REQ2 = N_REQ2 + 1
               CALL MPI_RECV_INIT(M3%N_PART_ADOPT,SIZE(M3%N_PART_ADOPT),MPI_INTEGER,SNODE,NOM,MPI_COMM_WORLD,&
                                  REQ2(N_REQ2),IERR)
            ENDIF

            N_REQ3 = N_REQ3 + 1
            CALL MPI_RECV_INIT(M3%REAL_RECV_PKG3(1),SIZE(M3%REAL_RECV_PKG3),MPI_DOUBLE_PRECISION,SNODE,NOM,MPI_COMM_WORLD,&
                               REQ3(N_REQ3),IERR)

            IF (SOLID_HT3D) THEN
               N_REQ4 = N_REQ4 + 1
               CALL MPI_RECV_INIT(M3%REAL_RECV_PKG4(1),SIZE(M3%REAL_RECV_PKG4),MPI_DOUBLE_PRECISION,SNODE,NOM,MPI_COMM_WORLD,&
                                  REQ4(N_REQ4),IERR)
            ENDIF

            N_REQ7 = N_REQ7 + 1
            CALL MPI_RECV_INIT(M3%REAL_RECV_PKG7(1),SIZE(M3%REAL_RECV_PKG7),MPI_DOUBLE_PRECISION,SNODE,NOM,MPI_COMM_WORLD,&
                               REQ7(N_REQ7),IERR)

            N_REQ8 = N_REQ8 + 1
            CALL MPI_RECV_INIT(M3%BOUNDARY_TYPE(0),SIZE(M3%BOUNDARY_TYPE),MPI_INTEGER,SNODE,NOM,MPI_COMM_WORLD,&
                               REQ8(N_REQ8),IERR)

            IF (RADIATION) THEN
               N_REQ5 = N_REQ5 + 1
               CALL MPI_RECV_INIT(M3%REAL_RECV_PKG5(1),SIZE(M3%REAL_RECV_PKG5),MPI_DOUBLE_PRECISION,SNODE,NOM,MPI_COMM_WORLD,&
                                  REQ5(N_REQ5),IERR)
            ENDIF

            IF (LEVEL_SET_MODE>0 .OR. TERRAIN_CASE) THEN
               N_REQ14 = N_REQ14 + 1
               CALL MPI_RECV_INIT(M3%REAL_RECV_PKG14(1),SIZE(M3%REAL_RECV_PKG14),MPI_DOUBLE_PRECISION,SNODE,NOM,MPI_COMM_WORLD,&
                                  REQ14(N_REQ14),IERR)
            ENDIF

         ENDIF

      ENDIF INITIALIZATION_IF

      ! Exchange BACK_WALL information

      IF (CODE==8) THEN
         N_REQ=MIN(N_REQ+1,SIZE(REQ))
         CALL MPI_IRECV(M3%N_WALL_CELLS_SEND,1,MPI_INTEGER,SNODE,NOM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      ENDIF

      IF (CODE==9 .AND. M3%N_WALL_CELLS_SEND>0) THEN
            N_REQ=MIN(N_REQ+1,SIZE(REQ))
            CALL MPI_IRECV(M3%WALL_CELL_INDICES_SEND,SIZE(M3%WALL_CELL_INDICES_SEND),MPI_INTEGER,SNODE,NOM,MPI_COMM_WORLD,&
                           REQ(N_REQ),IERR)
      ENDIF

      IF (CODE==10 .AND. M3%N_EXPOSED_WALL_CELLS>0) THEN
         N_REQ6 = N_REQ6 + 1
         CALL MPI_RECV_INIT(M3%REAL_RECV_PKG6(1),SIZE(M3%REAL_RECV_PKG6),MPI_DOUBLE_PRECISION,SNODE,NOM,MPI_COMM_WORLD,&
                            REQ6(N_REQ6),IERR)
      ENDIF

      IF (CODE==11) THEN
         IF (.NOT.ALLOCATED(M4%PRESSURE_ZONE)) ALLOCATE(M4%PRESSURE_ZONE(0:M4%IBP1,0:M4%JBP1,0:M4%KBP1))
         N_REQ = N_REQ + 1
         CALL MPI_IRECV(M4%PRESSURE_ZONE(0,0,0),SIZE(M4%PRESSURE_ZONE),MPI_INTEGER,SNODE,NOM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      ENDIF

      ! PARTICLEs

      IF (CODE==6 .AND. OMESH_PARTICLES) THEN
         DO N=1,N_LAGRANGIAN_CLASSES
            IF (M3%N_PART_ADOPT(N)==0) CYCLE
            LPC => LAGRANGIAN_PARTICLE_CLASS(N)
            N_REQ=MIN(N_REQ+1,SIZE(REQ))
            N_STORAGE_SLOTS = M3%ADOPT_PARTICLE_STORAGE(N)%N_STORAGE_SLOTS
            CALL MPI_IRECV(M3%ADOPT_PARTICLE_STORAGE(N)%REALS(1,1),LPC%N_STORAGE_REALS*N_STORAGE_SLOTS, &
                           MPI_DOUBLE_PRECISION,SNODE,NOM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
            N_REQ=MIN(N_REQ+1,SIZE(REQ))
            CALL MPI_IRECV(M3%ADOPT_PARTICLE_STORAGE(N)%INTEGERS(1,1),LPC%N_STORAGE_INTEGERS*N_STORAGE_SLOTS, &
                           MPI_INTEGER,SNODE,NOM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
            N_REQ=MIN(N_REQ+1,SIZE(REQ))
            CALL MPI_IRECV(M3%ADOPT_PARTICLE_STORAGE(N)%LOGICALS(1,1),LPC%N_STORAGE_LOGICALS*N_STORAGE_SLOTS, &
                           MPI_LOGICAL,SNODE,NOM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
         ENDDO
      ENDIF

   ENDDO OTHER_MESH_LOOP

ENDDO MESH_LOOP

! Receive EVACuation information

DO NOM=1,NMESHES
   SNODE = PROCESS(NOM)
   IF (CODE==6 .AND. EXCHANGE_EVACUATION .AND. MYID==MAX(0,EVAC_PROCESS) .AND. .NOT.EVACUATION_ONLY(NOM)) THEN
      M4=>MESHES(NOM)
      TAG_EVAC = NOM*(MAX(0,EVAC_PROCESS)+1)*CODE*10
      IWW = (M4%IBAR+2)*(M4%JBAR+2)*(M4%KBAR+2)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_IRECV(M4%ZZ(0,0,0,1),IWW*N_TRACKED_SPECIES,MPI_DOUBLE_PRECISION,SNODE,TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_IRECV(M4%RHO(0,0,0),IWW,MPI_DOUBLE_PRECISION,SNODE,TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_IRECV(M4%RSUM(0,0,0),IWW,MPI_DOUBLE_PRECISION,SNODE,TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_IRECV(M4%TMP(0,0,0),IWW,MPI_DOUBLE_PRECISION,SNODE,TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_IRECV(M4%UII(0,0,0),IWW,MPI_DOUBLE_PRECISION,SNODE,TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_IRECV(M4%CELL_INDEX(0,0,0),IWW,MPI_INTEGER,SNODE,TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      IWW = MAXVAL(M4%CELL_INDEX)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_IRECV(M4%SOLID(0),IWW,MPI_LOGICAL,SNODE,TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
   ENDIF
ENDDO

T_USED(11)=T_USED(11) + CURRENT_TIME() - TNOW
END SUBROUTINE POST_RECEIVES


SUBROUTINE MESH_EXCHANGE(CODE)

! Exchange Information between Meshes

REAL(EB) :: TNOW
INTEGER, INTENT(IN) :: CODE
INTEGER :: NM,II,JJ,KK,LL,LLL,N,RNODE,SNODE,IMIN,IMAX,JMIN,JMAX,KMIN,KMAX,IJK_SIZE,N_STORAGE_SLOTS,N_NEW_STORAGE_SLOTS
INTEGER :: NN1,NN2,IPC,CNT,IBC,STORAGE_INDEX_SAVE,II1,II2,JJ1,JJ2,KK1,KK2,NQT2,NN,IOR,NRA,NRA_MAX,AIC
REAL(EB), POINTER, DIMENSION(:,:) :: PHI_LS_P
REAL(EB), POINTER, DIMENSION(:,:,:) :: HP,HP2,RHOP,RHOP2,DP,DP2,UP,UP2,VP,VP2,WP,WP2
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP,ZZP2
REAL(EB) :: XI,YJ,ZK
TYPE (LAGRANGIAN_PARTICLE_TYPE), POINTER :: LP
TYPE (LAGRANGIAN_PARTICLE_CLASS_TYPE), POINTER :: LPC

IF(CC_IBM .AND. CC_FORCE_PRESSIT) CALL MESH_CC_EXCHANGE2(CODE)

TNOW = CURRENT_TIME()

! Special circumstances when doing the radiation exchange (CODE=2)

IF (CODE==2 .AND. (.NOT.EXCHANGE_RADIATION .OR. .NOT.RADIATION)) RETURN

! Ensure that all MPI processes wait here until all are ready to proceed

CALL MPI_BARRIER(MPI_COMM_WORLD,IERR)

! Loop over all meshes that have information to send

SENDING_MESH_LOOP: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   IF (EVACUATION_ONLY(NM)) CYCLE SENDING_MESH_LOOP

   M =>MESHES(NM)
   M5=>MESHES(NM)%OMESH(NM)

   ! Information about Mesh NM is packed into SEND packages and shipped out to the other meshes (machines) via MPI

   RECEIVING_MESH_LOOP: DO NOM=1,NMESHES

      M3=>MESHES(NM)%OMESH(NOM)
      IF (M3%NIC_S==0 .AND. M3%NIC_R==0)  CYCLE RECEIVING_MESH_LOOP
      IF (EVACUATION_ONLY(NOM)) CYCLE RECEIVING_MESH_LOOP

      RNODE = PROCESS(NOM)
      SNODE = PROCESS(NM)

      M4=>MESHES(NOM)

      IF (CODE>0) THEN
         IF (EVACUATION_SKIP(NM) .OR. EVACUATION_SKIP(NOM))  CYCLE RECEIVING_MESH_LOOP
      ENDIF

      IMIN = M3%I_MIN_S
      IMAX = M3%I_MAX_S
      JMIN = M3%J_MIN_S
      JMAX = M3%J_MAX_S
      KMIN = M3%K_MIN_S
      KMAX = M3%K_MAX_S

      IJK_SIZE = (IMAX-IMIN+1)*(JMAX-JMIN+1)*(KMAX-KMIN+1)

      ! Set up sends for one-time exchanges or persistent send/receives.

      INITIALIZE_SEND_IF: IF (CODE==0) THEN

         IF (RNODE/=SNODE) THEN
            N_REQ=MIN(N_REQ+1,SIZE(REQ))
            CALL MPI_ISEND(M%CELL_INDEX(0,0,0),SIZE(M%CELL_INDEX),MPI_INTEGER,RNODE,NM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
            N_REQ=MIN(N_REQ+1,SIZE(REQ))
            CALL MPI_ISEND(M%SOLID(0),SIZE(M%SOLID),MPI_INTEGER,RNODE,NM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
            N_REQ=MIN(N_REQ+1,SIZE(REQ))
            CALL MPI_ISEND(M%WALL_INDEX(0,-3),SIZE(M%WALL_INDEX),MPI_INTEGER,RNODE,NM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
            N_REQ=MIN(N_REQ+1,SIZE(REQ))
            CALL MPI_ISEND(M%OBST_INDEX_C(0),SIZE(M%OBST_INDEX_C),MPI_INTEGER,RNODE,NM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
         ENDIF

         IF (M3%NIC_S>0 .AND. RNODE/=SNODE) THEN

            ! Determine the maximum number of radiation angles that are to be sent

            NRA_MAX = 0
            IF (RADIATION) THEN
               DO AIC=1,ANGLE_INCREMENT
                  DO LL=1,M3%NIC_S
                     NRA = 0
                     DO N=NUMBER_RADIATION_ANGLES-AIC+1,1,-ANGLE_INCREMENT
                        IF (DLN(M3%IOR_S(LL),N)>0._EB) NRA = NRA + 1
                     ENDDO
                     NRA_MAX = MAX(NRA_MAX,NRA)
                  ENDDO
               ENDDO
            ENDIF

            ! Allocate 1-D arrays to hold major mesh variables that are to be sent to neighboring meshes

            ALLOCATE(M3%REAL_SEND_PKG1(M3%NIC_S*(6+2*N_TOTAL_SCALARS)))
            ALLOCATE(M3%REAL_SEND_PKG3(IJK_SIZE*4))
            ALLOCATE(M3%REAL_SEND_PKG5(NRA_MAX*NUMBER_SPECTRAL_BANDS*M3%NIC_S))
            ALLOCATE(M3%REAL_SEND_PKG7(M3%NIC_S*3))

            IF (SOLID_HT3D) ALLOCATE(M3%REAL_SEND_PKG4(M3%NIC_S*2))

            IF (LEVEL_SET_MODE>0 .OR. TERRAIN_CASE) ALLOCATE(M3%REAL_SEND_PKG14(4*M3%NIC_S))

         ENDIF

         ! Initialize persistent send requests

         IF (M3%NIC_S>0 .AND. RNODE/=SNODE) THEN

            N_REQ1 = N_REQ1 + 1
            CALL MPI_SEND_INIT(M3%REAL_SEND_PKG1(1),SIZE(M3%REAL_SEND_PKG1),MPI_DOUBLE_PRECISION,RNODE,NM,MPI_COMM_WORLD,&
                               REQ1(N_REQ1),IERR)

            IF (OMESH_PARTICLES) THEN
               N_REQ2 = N_REQ2 + 1
               CALL MPI_SEND_INIT(M3%N_PART_ORPHANS,SIZE(M3%N_PART_ORPHANS),MPI_INTEGER,RNODE,NM,MPI_COMM_WORLD,&
                                  REQ2(N_REQ2),IERR)
            ENDIF

            N_REQ3 = N_REQ3 + 1
            CALL MPI_SEND_INIT(M3%REAL_SEND_PKG3(1),SIZE(M3%REAL_SEND_PKG3),MPI_DOUBLE_PRECISION,RNODE,NM,MPI_COMM_WORLD,&
                               REQ3(N_REQ3),IERR)

            IF (SOLID_HT3D) THEN
               N_REQ4 = N_REQ4 + 1
               CALL MPI_SEND_INIT(M3%REAL_SEND_PKG4(1),SIZE(M3%REAL_SEND_PKG4),MPI_DOUBLE_PRECISION,RNODE,NM,MPI_COMM_WORLD,&
                                  REQ4(N_REQ4),IERR)
            ENDIF

            N_REQ7 = N_REQ7 + 1
            CALL MPI_SEND_INIT(M3%REAL_SEND_PKG7(1),SIZE(M3%REAL_SEND_PKG7),MPI_DOUBLE_PRECISION,RNODE,NM,MPI_COMM_WORLD,&
                               REQ7(N_REQ7),IERR)

            N_REQ8 = N_REQ8 + 1
            CALL MPI_SEND_INIT(M5%BOUNDARY_TYPE(0),SIZE(M5%BOUNDARY_TYPE),MPI_INTEGER,RNODE,NM,MPI_COMM_WORLD,&
                               REQ8(N_REQ8),IERR)

            IF (RADIATION) THEN
               N_REQ5 = N_REQ5 + 1
               CALL MPI_SEND_INIT(M3%REAL_SEND_PKG5(1),SIZE(M3%REAL_SEND_PKG5),MPI_DOUBLE_PRECISION,RNODE,NM,MPI_COMM_WORLD,&
                                  REQ5(N_REQ5),IERR)
            ENDIF

            IF (LEVEL_SET_MODE>0 .OR. TERRAIN_CASE) THEN
               N_REQ14 = N_REQ14 + 1
               CALL MPI_SEND_INIT(M3%REAL_SEND_PKG14(1),SIZE(M3%REAL_SEND_PKG14),MPI_DOUBLE_PRECISION,RNODE,NM,MPI_COMM_WORLD,&
                                  REQ14(N_REQ14),IERR)
            ENDIF


         ENDIF

      ENDIF INITIALIZE_SEND_IF

      ! Exchange the number of solid surface cells whose back side is in another mesh

      IF (CODE==8) THEN
         IF (RNODE/=SNODE) THEN
            N_REQ=MIN(N_REQ+1,SIZE(REQ))
            CALL MPI_ISEND(M3%N_EXPOSED_WALL_CELLS,1,MPI_INTEGER,RNODE,NM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            M2%N_WALL_CELLS_SEND = M3%N_EXPOSED_WALL_CELLS
         ENDIF
      ENDIF

      IF (CODE==9 .AND. M3%N_EXPOSED_WALL_CELLS>0) THEN
         IF (RNODE/=SNODE) THEN
            N_REQ=MIN(N_REQ+1,SIZE(REQ))
            CALL MPI_ISEND(M3%EXPOSED_WALL_CELL_BACK_INDICES,SIZE(M3%EXPOSED_WALL_CELL_BACK_INDICES),MPI_INTEGER,RNODE,NM,&
                           MPI_COMM_WORLD,REQ(N_REQ),IERR)
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            M2%WALL_CELL_INDICES_SEND = M3%EXPOSED_WALL_CELL_BACK_INDICES
         ENDIF
      ENDIF

      IF (CODE==10 .AND. M3%N_WALL_CELLS_SEND>0) THEN
         IF (RNODE/=SNODE) THEN
            N_REQ6 = N_REQ6 + 1
            CALL MPI_SEND_INIT(M3%REAL_SEND_PKG6(1),SIZE(M3%REAL_SEND_PKG6),MPI_DOUBLE_PRECISION,RNODE,NM,MPI_COMM_WORLD,&
                                REQ6(N_REQ6),IERR)
         ENDIF
      ENDIF

      ! Exchange of density and species mass fractions following the PREDICTOR update (CODE=1) or CORRECTOR (CODE=4) update

      IF ((CODE==1.OR.CODE==4) .AND. M3%NIC_S>0) THEN
         IF (CODE==1) THEN
            RHOP => M%RHOS ; DP => M%D  ; ZZP => M%ZZS
         ELSE
            RHOP => M%RHO  ; DP => M%DS ; ZZP => M%ZZ
         ENDIF
         IF (RNODE/=SNODE) THEN
            NQT2 = 6+2*N_TOTAL_SCALARS
            PACK_REAL_SEND_PKG1: DO LL=1,M3%NIC_S
               II1 = M3%IIO_S(LL) ; II2 = II1
               JJ1 = M3%JJO_S(LL) ; JJ2 = JJ1
               KK1 = M3%KKO_S(LL) ; KK2 = KK1
               SELECT CASE(M3%IOR_S(LL))
                  CASE(-1) ; II2=II1+1
                  CASE( 1) ; II2=II1-1
                  CASE(-2) ; JJ2=JJ1+1
                  CASE( 2) ; JJ2=JJ1-1
                  CASE(-3) ; KK2=KK1+1
                  CASE( 3) ; KK2=KK1-1
               END SELECT
               M3%REAL_SEND_PKG1(NQT2*(LL-1)+1) =   RHOP(II1,JJ1,KK1)
               M3%REAL_SEND_PKG1(NQT2*(LL-1)+2) =   RHOP(II2,JJ2,KK2)
               M3%REAL_SEND_PKG1(NQT2*(LL-1)+3) =   M%MU(II1,JJ1,KK1)
               M3%REAL_SEND_PKG1(NQT2*(LL-1)+4) = M%KRES(II1,JJ1,KK1)
               M3%REAL_SEND_PKG1(NQT2*(LL-1)+5) =     DP(II1,JJ1,KK1)
               M3%REAL_SEND_PKG1(NQT2*(LL-1)+6) =    M%Q(II1,JJ1,KK1)
               DO NN=1,N_TOTAL_SCALARS
                  M3%REAL_SEND_PKG1(NQT2*(LL-1)+6+2*NN-1) = ZZP(II1,JJ1,KK1,NN)
                  M3%REAL_SEND_PKG1(NQT2*(LL-1)+6+2*NN  ) = ZZP(II2,JJ2,KK2,NN)
               ENDDO
            ENDDO PACK_REAL_SEND_PKG1
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            IF (CODE==1) THEN
               RHOP2 => M2%RHOS ; DP2 => M2%D  ; ZZP2 => M2%ZZS
            ELSE
               RHOP2 => M2%RHO  ; DP2 => M2%DS ; ZZP2 => M2%ZZ
            ENDIF
            RHOP2(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)   = RHOP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            M2%MU(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)   = M%MU(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            M2%KRES(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX) = M%KRES(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            M2%Q(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)    = M%Q(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            DP2(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)     = DP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            ZZP2(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX,1:N_TOTAL_SCALARS)= ZZP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX,1:N_TOTAL_SCALARS)
         ENDIF
      ENDIF

      ! Exchange velocity/pressure info for ITERATE_PRESSURE

      IF (CODE==5 .AND. M3%NIC_S>0) THEN
         IF (PREDICTOR) THEN
            HP => M%H
         ELSE
            HP => M%HS
         ENDIF
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG7: DO LL=1,M3%NIC_S
               SELECT CASE(M3%IOR_S(LL))
                  CASE(-1) ; M3%REAL_SEND_PKG7(3*LL-2) = M%FVX(M3%IIO_S(LL)-1,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                             M3%REAL_SEND_PKG7(3*LL-1) =    HP(M3%IIO_S(LL)-1,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                             M3%REAL_SEND_PKG7(3*LL  ) =    HP(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                  CASE( 1) ; M3%REAL_SEND_PKG7(3*LL-2) = M%FVX(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                             M3%REAL_SEND_PKG7(3*LL-1) =    HP(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                             M3%REAL_SEND_PKG7(3*LL  ) =    HP(M3%IIO_S(LL)+1,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                  CASE(-2) ; M3%REAL_SEND_PKG7(3*LL-2) = M%FVY(M3%IIO_S(LL)  ,M3%JJO_S(LL)-1,M3%KKO_S(LL)  )
                             M3%REAL_SEND_PKG7(3*LL-1) =    HP(M3%IIO_S(LL)  ,M3%JJO_S(LL)-1,M3%KKO_S(LL)  )
                             M3%REAL_SEND_PKG7(3*LL  ) =    HP(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                  CASE( 2) ; M3%REAL_SEND_PKG7(3*LL-2) = M%FVY(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                             M3%REAL_SEND_PKG7(3*LL-1) =    HP(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                             M3%REAL_SEND_PKG7(3*LL  ) =    HP(M3%IIO_S(LL)  ,M3%JJO_S(LL)+1,M3%KKO_S(LL)  )
                  CASE(-3) ; M3%REAL_SEND_PKG7(3*LL-2) = M%FVZ(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)-1)
                             M3%REAL_SEND_PKG7(3*LL-1) =    HP(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)-1)
                             M3%REAL_SEND_PKG7(3*LL  ) =    HP(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                  CASE( 3) ; M3%REAL_SEND_PKG7(3*LL-2) = M%FVZ(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                             M3%REAL_SEND_PKG7(3*LL-1) =    HP(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)  )
                             M3%REAL_SEND_PKG7(3*LL  ) =    HP(M3%IIO_S(LL)  ,M3%JJO_S(LL)  ,M3%KKO_S(LL)+1)
               END SELECT
            ENDDO PACK_REAL_SEND_PKG7
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            IF (PREDICTOR) THEN
               HP2 => M2%H
            ELSE
               HP2 => M2%HS
            ENDIF
            M2%FVX(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX) = M%FVX(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            M2%FVY(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX) = M%FVY(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            M2%FVZ(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX) = M%FVZ(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            HP2(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)    = HP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         ENDIF
      ENDIF

      ! Send pressure information at the end of the PREDICTOR (CODE=3) or CORRECTOR (CODE=6) stage of the time step

      IF ((CODE==3.OR.CODE==6) .AND. M3%NIC_S>0) THEN
         IF (CODE==3) THEN
            HP => M%HS ; UP => M%US ; VP => M%VS ; WP => M%WS
         ELSE
            HP => M%H  ; UP => M%U  ; VP => M%V  ; WP => M%W
         ENDIF
         IF (RNODE/=SNODE) THEN
            LL = 0
            DO KK=KMIN,KMAX
               DO JJ=JMIN,JMAX
                  DO II=IMIN,IMAX
                     M3%REAL_SEND_PKG3(LL+1) = HP(II,JJ,KK)
                     M3%REAL_SEND_PKG3(LL+2) = UP(II,JJ,KK)
                     M3%REAL_SEND_PKG3(LL+3) = VP(II,JJ,KK)
                     M3%REAL_SEND_PKG3(LL+4) = WP(II,JJ,KK)
                     LL = LL+4
                  ENDDO
               ENDDO
            ENDDO
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            IF (CODE==3) THEN
               HP2 => M2%HS ; UP2 => M2%US ; VP2 => M2%VS ; WP2 => M2%WS
            ELSE
               HP2 => M2%H  ; UP2 => M2%U  ; VP2 => M2%V  ; WP2 => M2%W
            ENDIF
            HP2(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX) = HP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            UP2(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX) = UP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            VP2(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX) = VP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
            WP2(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX) = WP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         ENDIF
      ENDIF

      ! Exchange BOUNDARY_TYPE following the CORRECTOR stage of the time step

      IF (CODE==0 .OR. CODE==6) THEN
         IF (RNODE/=SNODE) THEN
            DO IW=1,M%N_EXTERNAL_WALL_CELLS
               M5%BOUNDARY_TYPE(IW) = M%WALL(IW)%BOUNDARY_TYPE
            ENDDO
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            M2%BOUNDARY_TYPE(1:M%N_EXTERNAL_WALL_CELLS) = M5%BOUNDARY_TYPE(1:M%N_EXTERNAL_WALL_CELLS)
         ENDIF
      ENDIF

      ! Exchange BACK_WALL information

      IF (CODE==6) THEN
         IF (RNODE/=SNODE) THEN
            LL = 0
            DO II=1,M%OMESH(NOM)%N_WALL_CELLS_SEND
               IW = M%OMESH(NOM)%WALL_CELL_INDICES_SEND(II)
               M3%REAL_SEND_PKG6(LL+1) = M%WALL(IW)%ONE_D%Q_RAD_IN
               M3%REAL_SEND_PKG6(LL+2) = M%TMP(M%WALL(IW)%ONE_D%IIG,M%WALL(IW)%ONE_D%JJG,M%WALL(IW)%ONE_D%KKG)
               LL = LL+2
            ENDDO
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            DO II=1,M2%N_EXPOSED_WALL_CELLS
               IW = M2%EXPOSED_WALL_CELL_BACK_INDICES(II)
               M2%EXPOSED_WALL(II)%Q_RAD_IN = M%WALL(IW)%ONE_D%Q_RAD_IN
               M2%EXPOSED_WALL(II)%TMP_GAS  = M%TMP(M%WALL(IW)%ONE_D%IIG,M%WALL(IW)%ONE_D%JJG,M%WALL(IW)%ONE_D%KKG)
            ENDDO
         ENDIF
      ENDIF

      ! Send out radiation info

      SEND_RADIATION: IF (CODE==2 .AND. M3%NIC_S>0) THEN
         IF (RNODE/=SNODE) THEN
            IF (ICYC>1) ANG_INC_COUNTER = M%ANGLE_INC_COUNTER
            LLL = 0
            PACK_REAL_SEND_PKG5: DO LL=1,M3%NIC_S
               IOR = M3%IOR_S(LL)
               DO NN2=1,NUMBER_SPECTRAL_BANDS
                  DO NN1=NUMBER_RADIATION_ANGLES-ANG_INC_COUNTER+1,1,-ANGLE_INCREMENT
                     IF (DLN(IOR,NN1)<=0._EB) CYCLE
                     LLL = LLL + 1
                     M3%REAL_SEND_PKG5(LLL) = M3%IL_S(LL,NN1,NN2)
                  ENDDO
               ENDDO
            ENDDO PACK_REAL_SEND_PKG5
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            M2%IL_R = M3%IL_S
         ENDIF
      ENDIF SEND_RADIATION

      ! Get Number of PARTICLE Orphans (PARTICLEs that have left other meshes and are waiting to be picked up)

      IF (CODE==7 .AND. OMESH_PARTICLES) THEN
         IF (RNODE==SNODE) THEN
            M2=>MESHES(NOM)%OMESH(NM)
            M2%N_PART_ADOPT = M3%N_PART_ORPHANS
         ENDIF
      ENDIF

      ! Sending/Receiving PARTICLE Buffer Arrays

      IF_SEND_PARTICLES: IF (CODE==6 .AND. OMESH_PARTICLES) THEN

         NODE_CHECK_PARTICLE: IF (SNODE/=RNODE) THEN

            DO IPC=1,N_LAGRANGIAN_CLASSES

               IF (M3%N_PART_ORPHANS(IPC)==0) CYCLE

               LPC => LAGRANGIAN_PARTICLE_CLASS(IPC)
               IBC = LPC%SURF_INDEX

               N_STORAGE_SLOTS = M3%ORPHAN_PARTICLE_STORAGE(IPC)%N_STORAGE_SLOTS
               N_REQ=MIN(N_REQ+1,SIZE(REQ))
               CALL MPI_ISEND(M3%ORPHAN_PARTICLE_STORAGE(IPC)%REALS(1,1),LPC%N_STORAGE_REALS*N_STORAGE_SLOTS,MPI_DOUBLE_PRECISION, &
                              RNODE,NM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
               N_REQ=MIN(N_REQ+1,SIZE(REQ))
               CALL MPI_ISEND(M3%ORPHAN_PARTICLE_STORAGE(IPC)%INTEGERS(1,1),LPC%N_STORAGE_INTEGERS*N_STORAGE_SLOTS,MPI_INTEGER, &
                              RNODE,NM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
               N_REQ=MIN(N_REQ+1,SIZE(REQ))
               CALL MPI_ISEND(M3%ORPHAN_PARTICLE_STORAGE(IPC)%LOGICALS(1,1),LPC%N_STORAGE_LOGICALS*N_STORAGE_SLOTS,MPI_LOGICAL, &
                              RNODE,NM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
            ENDDO

         ELSE NODE_CHECK_PARTICLE

            M2 => MESHES(NOM)%OMESH(NM)

            DO IPC=1,N_LAGRANGIAN_CLASSES
               LPC => LAGRANGIAN_PARTICLE_CLASS(IPC)
               M2%ADOPT_PARTICLE_STORAGE(IPC)%REALS    = M3%ORPHAN_PARTICLE_STORAGE(IPC)%REALS
               M2%ADOPT_PARTICLE_STORAGE(IPC)%INTEGERS = M3%ORPHAN_PARTICLE_STORAGE(IPC)%INTEGERS
               M2%ADOPT_PARTICLE_STORAGE(IPC)%LOGICALS = M3%ORPHAN_PARTICLE_STORAGE(IPC)%LOGICALS
            ENDDO

         ENDIF NODE_CHECK_PARTICLE

      ENDIF IF_SEND_PARTICLES

      IF ((CODE==1.OR.CODE==4) .AND. M3%NIC_S>0 .AND. SOLID_HT3D) THEN
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG4: DO LL=1,M3%NIC_S
               II1 = M3%IIO_S(LL) ; II2 = II1
               JJ1 = M3%JJO_S(LL) ; JJ2 = JJ1
               KK1 = M3%KKO_S(LL) ; KK2 = KK1
               SELECT CASE(M3%IOR_S(LL))
                  CASE(-1) ; II1=M3%IIO_S(LL)   ; II2=II1+1
                  CASE( 1) ; II1=M3%IIO_S(LL)-1 ; II2=II1+1
                  CASE(-2) ; JJ1=M3%JJO_S(LL)   ; JJ2=JJ1+1
                  CASE( 2) ; JJ1=M3%JJO_S(LL)-1 ; JJ2=JJ1+1
                  CASE(-3) ; KK1=M3%KKO_S(LL)   ; KK2=KK1+1
                  CASE( 3) ; KK1=M3%KKO_S(LL)-1 ; KK2=KK1+1
               END SELECT
               M3%REAL_SEND_PKG4(2*(LL-1)+1) = M%TMP(II1,JJ1,KK1)
               M3%REAL_SEND_PKG4(2*(LL-1)+2) = M%TMP(II2,JJ2,KK2)
            ENDDO PACK_REAL_SEND_PKG4
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            M2%TMP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)= M%TMP(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         ENDIF
      ENDIF

      IF (CODE==11) THEN
         IF (RNODE/=SNODE) THEN
            N_REQ = N_REQ + 1
            CALL MPI_ISEND(M%PRESSURE_ZONE(0,0,0),SIZE(M%PRESSURE_ZONE),MPI_INTEGER,RNODE,NM,MPI_COMM_WORLD,REQ(N_REQ),IERR)
         ENDIF
      ENDIF

      IF (CODE==14 .AND. M3%NIC_S>0) THEN
         IF (PREDICTOR) THEN
            PHI_LS_P => M%PHI1_LS
         ELSE
            PHI_LS_P => M%PHI_LS
         ENDIF
         IF (RNODE/=SNODE) THEN
            NQT2 = 4
            PACK_REAL_SEND_PKG14: DO LL=1,M3%NIC_S
               II1 = M3%IIO_S(LL)
               JJ1 = M3%JJO_S(LL)
               M3%REAL_SEND_PKG14(NQT2*(LL-1)+1) = PHI_LS_P(II1,JJ1)
               M3%REAL_SEND_PKG14(NQT2*(LL-1)+2) = M%U_LS(II1,JJ1)
               M3%REAL_SEND_PKG14(NQT2*(LL-1)+3) = M%V_LS(II1,JJ1)
               M3%REAL_SEND_PKG14(NQT2*(LL-1)+4) = M%Z_LS(II1,JJ1)
            ENDDO PACK_REAL_SEND_PKG14
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            IF (PREDICTOR) THEN
               M2%PHI1_LS(IMIN:IMAX,JMIN:JMAX) = PHI_LS_P(IMIN:IMAX,JMIN:JMAX)
            ELSE
               M2%PHI_LS(IMIN:IMAX,JMIN:JMAX)  = PHI_LS_P(IMIN:IMAX,JMIN:JMAX)
            ENDIF
            M2%U_LS(IMIN:IMAX,JMIN:JMAX) = M%U_LS(IMIN:IMAX,JMIN:JMAX)
            M2%V_LS(IMIN:IMAX,JMIN:JMAX) = M%V_LS(IMIN:IMAX,JMIN:JMAX)
            M2%Z_LS(IMIN:IMAX,JMIN:JMAX) = M%Z_LS(IMIN:IMAX,JMIN:JMAX)
         ENDIF
      ENDIF


   ENDDO RECEIVING_MESH_LOOP

ENDDO SENDING_MESH_LOOP

! Send information needed by EVACuation routine

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (CODE==6 .AND. EXCHANGE_EVACUATION.AND.MYID/=MAX(0,EVAC_PROCESS) .AND..NOT.EVACUATION_ONLY(NM)) THEN
      M => MESHES(NM)
      TAG_EVAC = NM*(MAX(0,EVAC_PROCESS)+1)*CODE*10
      IWW = (M%IBAR+2)*(M%JBAR+2)*(M%KBAR+2)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_ISEND(M%ZZ(0,0,0,1),IWW*N_TRACKED_SPECIES,MPI_DOUBLE_PRECISION,MAX(0,EVAC_PROCESS),&
           TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_ISEND(M%RHO(0,0,0),IWW,MPI_DOUBLE_PRECISION,MAX(0,EVAC_PROCESS),TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_ISEND(M%RSUM(0,0,0),IWW,MPI_DOUBLE_PRECISION,MAX(0,EVAC_PROCESS),TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_ISEND(M%TMP(0,0,0),IWW,MPI_DOUBLE_PRECISION,MAX(0,EVAC_PROCESS),TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_ISEND(M%UII(0,0,0),IWW,MPI_DOUBLE_PRECISION,MAX(0,EVAC_PROCESS),TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_ISEND(M%CELL_INDEX(0,0,0),IWW,MPI_INTEGER,MAX(0,EVAC_PROCESS),TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
      IWW = MAXVAL(M%CELL_INDEX)
      N_REQ=MIN(N_REQ+1,SIZE(REQ))
      CALL MPI_ISEND(M%SOLID(0),IWW,MPI_LOGICAL,MAX(0,EVAC_PROCESS),TAG_EVAC,MPI_COMM_WORLD,REQ(N_REQ),IERR)
   ENDIF
ENDDO


! Halt communications until all processes are ready to receive the data.

IF (N_MPI_PROCESSES>1 .AND. CODE/=1 .AND. CODE/=3 .AND. CODE/=4 .AND. CODE/=5 .AND. N_REQ>0) THEN
   CALL TIMEOUT('REQ',N_REQ,REQ(1:N_REQ))
ENDIF

IF (N_MPI_PROCESSES>1 .AND. (CODE==1.OR.CODE==4) .AND. N_REQ1>0) THEN
   CALL MPI_STARTALL(N_REQ1,REQ1(1:N_REQ1),IERR)
   CALL TIMEOUT('REQ1',N_REQ1,REQ1(1:N_REQ1))
ENDIF

IF (N_MPI_PROCESSES>1 .AND. CODE==7 .AND. OMESH_PARTICLES .AND. N_REQ2>0) THEN
   CALL MPI_STARTALL(N_REQ2,REQ2(1:N_REQ2),IERR)
   CALL TIMEOUT('REQ2',N_REQ2,REQ2(1:N_REQ2))
ENDIF

IF (N_MPI_PROCESSES>1 .AND. (CODE==3.OR.CODE==6) .AND. N_REQ3>0) THEN
   CALL MPI_STARTALL(N_REQ3,REQ3(1:N_REQ3),IERR)
   CALL TIMEOUT('REQ3',N_REQ3,REQ3(1:N_REQ3))
ENDIF

IF (N_MPI_PROCESSES>1 .AND. (CODE==1.OR.CODE==4) .AND. N_REQ4>0 .AND. SOLID_HT3D) THEN
   CALL MPI_STARTALL(N_REQ4,REQ4(1:N_REQ4),IERR)
   CALL TIMEOUT('REQ4',N_REQ4,REQ4(1:N_REQ4))
ENDIF

IF (N_MPI_PROCESSES>1 .AND. CODE==5 .AND. N_REQ7>0) THEN
   CALL MPI_STARTALL(N_REQ7,REQ7(1:N_REQ7),IERR)
   CALL TIMEOUT('REQ7',N_REQ7,REQ7(1:N_REQ7))
ENDIF

IF (N_MPI_PROCESSES>1 .AND. CODE==6 .AND. N_REQ6>0) THEN
   CALL MPI_STARTALL(N_REQ6,REQ6(1:N_REQ6),IERR)
   CALL TIMEOUT('REQ6',N_REQ6,REQ6(1:N_REQ6))
ENDIF

IF (N_MPI_PROCESSES>1 .AND. (CODE==0 .OR. CODE==6) .AND. N_REQ8>0) THEN
   CALL MPI_STARTALL(N_REQ8,REQ8(1:N_REQ8),IERR)
   CALL TIMEOUT('REQ8',N_REQ8,REQ8(1:N_REQ8))
ENDIF

IF (N_MPI_PROCESSES>1 .AND. CODE==2 .AND. N_REQ5>0) THEN
   CALL MPI_STARTALL(N_REQ5,REQ5(1:N_REQ5),IERR)
   CALL TIMEOUT('REQ5',N_REQ5,REQ5(1:N_REQ5))
ENDIF

IF (N_MPI_PROCESSES>1 .AND. CODE==14 .AND. N_REQ14>0) THEN
   CALL MPI_STARTALL(N_REQ14,REQ14(1:N_REQ14),IERR)
   CALL TIMEOUT('REQ14',N_REQ14,REQ14(1:N_REQ14))
ENDIF

! Receive the information sent above into the appropriate arrays.

SEND_MESH_LOOP: DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

IF (EVACUATION_ONLY(NOM)) CYCLE SEND_MESH_LOOP

SNODE = PROCESS(NOM)

   RECV_MESH_LOOP: DO NM=1,NMESHES

      M2=>MESHES(NOM)%OMESH(NM)
      IF (M2%NIC_S==0 .AND. M2%NIC_R==0) CYCLE RECV_MESH_LOOP
      IF (EVACUATION_ONLY(NM)) CYCLE RECV_MESH_LOOP
      IF (CODE>0 .AND. (EVACUATION_SKIP(NM).OR.EVACUATION_SKIP(NOM))) CYCLE RECV_MESH_LOOP

      RNODE = PROCESS(NM)

      M =>MESHES(NM)
      M4=>MESHES(NOM)

      IMIN = M2%I_MIN_R
      IMAX = M2%I_MAX_R
      JMIN = M2%J_MIN_R
      JMAX = M2%J_MAX_R
      KMIN = M2%K_MIN_R
      KMAX = M2%K_MAX_R

      ! Unpack densities and species mass fractions in the PREDICTOR (CODE=1) and CORRECTOR (CODE=4) step

      IF ((CODE==1.OR.CODE==4) .AND. M2%NIC_R>0 .AND. RNODE/=SNODE) THEN
            NQT2 = 6+2*N_TOTAL_SCALARS
            IF (CODE==1) THEN
               RHOP => M2%RHOS ; DP => M2%D  ; ZZP => M2%ZZS
            ELSE
               RHOP => M2%RHO  ; DP => M2%DS ; ZZP => M2%ZZ
            ENDIF
            UNPACK_REAL_RECV_PKG1: DO LL=1,M2%NIC_R
               II1 = M2%IIO_R(LL) ; II2 = II1
               JJ1 = M2%JJO_R(LL) ; JJ2 = JJ1
               KK1 = M2%KKO_R(LL) ; KK2 = KK1
               SELECT CASE(M2%IOR_R(LL))
                  CASE(-1) ; II2=II1+1
                  CASE( 1) ; II2=II1-1
                  CASE(-2) ; JJ2=JJ1+1
                  CASE( 2) ; JJ2=JJ1-1
                  CASE(-3) ; KK2=KK1+1
                  CASE( 3) ; KK2=KK1-1
               END SELECT
                  RHOP(II1,JJ1,KK1) = M2%REAL_RECV_PKG1(NQT2*(LL-1)+1)
                  RHOP(II2,JJ2,KK2) = M2%REAL_RECV_PKG1(NQT2*(LL-1)+2)
                 M2%MU(II1,JJ1,KK1) = M2%REAL_RECV_PKG1(NQT2*(LL-1)+3)
               M2%KRES(II1,JJ1,KK1) = M2%REAL_RECV_PKG1(NQT2*(LL-1)+4)
                    DP(II1,JJ1,KK1) = M2%REAL_RECV_PKG1(NQT2*(LL-1)+5)
                  M2%Q(II1,JJ1,KK1) = M2%REAL_RECV_PKG1(NQT2*(LL-1)+6)
               DO NN=1,N_TOTAL_SCALARS
                     ZZP(II1,JJ1,KK1,NN) = M2%REAL_RECV_PKG1(NQT2*(LL-1)+6+2*NN-1)
                     ZZP(II2,JJ2,KK2,NN) = M2%REAL_RECV_PKG1(NQT2*(LL-1)+6+2*NN  )
               ENDDO
            ENDDO UNPACK_REAL_RECV_PKG1
      ENDIF

      ! Unpack densities and species mass fractions following PREDICTOR exchange

      IF (CODE==5 .AND. M2%NIC_R>0 .AND. RNODE/=SNODE) THEN
         IF (PREDICTOR) THEN
            HP => M2%H
         ELSE
            HP => M2%HS
         ENDIF
         UNPACK_REAL_RECV_PKG7: DO LL=1,M2%NIC_R
            SELECT CASE(M2%IOR_R(LL))
               CASE(-1) ; M2%FVX(M2%IIO_R(LL)-1,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL-2)
                              HP(M2%IIO_R(LL)-1,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL-1)
                              HP(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL  )
               CASE( 1) ; M2%FVX(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL-2)
                              HP(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL-1)
                              HP(M2%IIO_R(LL)+1,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL  )
               CASE(-2) ; M2%FVY(M2%IIO_R(LL)  ,M2%JJO_R(LL)-1,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL-2)
                              HP(M2%IIO_R(LL)  ,M2%JJO_R(LL)-1,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL-1)
                              HP(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL  )
               CASE( 2) ; M2%FVY(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL-2)
                              HP(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL-1)
                              HP(M2%IIO_R(LL)  ,M2%JJO_R(LL)+1,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL  )
               CASE(-3) ; M2%FVZ(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)-1) = M2%REAL_RECV_PKG7(3*LL-2)
                              HP(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)-1) = M2%REAL_RECV_PKG7(3*LL-1)
                              HP(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL  )
               CASE( 3) ; M2%FVZ(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL-2)
                              HP(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)  ) = M2%REAL_RECV_PKG7(3*LL-1)
                              HP(M2%IIO_R(LL)  ,M2%JJO_R(LL)  ,M2%KKO_R(LL)+1) = M2%REAL_RECV_PKG7(3*LL  )
            END SELECT
         ENDDO UNPACK_REAL_RECV_PKG7
      ENDIF

      ! Unpack pressure following PREDICTOR stage of time step

      IF ((CODE==3.OR.CODE==6) .AND. M2%NIC_R>0 .AND. RNODE/=SNODE) THEN
         IF (CODE==3) THEN
            HP2 => M2%HS ; UP2 => M2%US ; VP2 => M2%VS ; WP2 => M2%WS
         ELSE
            HP2 => M2%H  ; UP2 => M2%U  ; VP2 => M2%V  ; WP2 => M2%W
         ENDIF
         LL = 0
         DO KK=KMIN,KMAX
            DO JJ=JMIN,JMAX
               DO II=IMIN,IMAX
                  HP2(II,JJ,KK) = M2%REAL_RECV_PKG3(LL+1)
                  UP2(II,JJ,KK) = M2%REAL_RECV_PKG3(LL+2)
                  VP2(II,JJ,KK) = M2%REAL_RECV_PKG3(LL+3)
                  WP2(II,JJ,KK) = M2%REAL_RECV_PKG3(LL+4)
                  LL = LL+4
               ENDDO
            ENDDO
         ENDDO
      ENDIF

      ! Unpack radiation information at the end of the CORRECTOR stage of the time step

      RECEIVE_RADIATION: IF (CODE==2 .AND. M2%NIC_R>0 .AND. RNODE/=SNODE) THEN
         IF (ICYC>1) ANG_INC_COUNTER = M4%ANGLE_INC_COUNTER
         LLL = 0
         UNPACK_REAL_RECV_PKG5: DO LL=1,M2%NIC_R
            IOR = M2%IOR_R(LL)
            DO NN2=1,NUMBER_SPECTRAL_BANDS
               DO NN1=NUMBER_RADIATION_ANGLES-ANG_INC_COUNTER+1,1,-ANGLE_INCREMENT
                  IF (DLN(IOR,NN1)<=0._EB) CYCLE
                  LLL = LLL + 1
                  M2%IL_R(LL,NN1,NN2) = M2%REAL_RECV_PKG5(LLL)
               ENDDO
            ENDDO
         ENDDO UNPACK_REAL_RECV_PKG5
      ENDIF RECEIVE_RADIATION

      ! Unpack back wall information at the end of the CORRECTOR stage of the time step

      RECEIVE_BACK_WALL: IF (CODE==6 .AND. SNODE/=RNODE) THEN
         LL = 0
         DO II=1,M2%N_EXPOSED_WALL_CELLS
            M2%EXPOSED_WALL(II)%Q_RAD_IN = M2%REAL_RECV_PKG6(LL+1)
            M2%EXPOSED_WALL(II)%TMP_GAS  = M2%REAL_RECV_PKG6(LL+2)
            LL = LL+2
         ENDDO
      ENDIF RECEIVE_BACK_WALL

      ! Sending/Receiving PARTICLE Buffer Arrays

      IF (CODE==7 .AND. OMESH_PARTICLES) THEN
         DO IPC=1,N_LAGRANGIAN_CLASSES
            IF (M2%N_PART_ADOPT(IPC)>M2%ADOPT_PARTICLE_STORAGE(IPC)%N_STORAGE_SLOTS) THEN
               N_NEW_STORAGE_SLOTS = M2%N_PART_ADOPT(IPC)-M2%ADOPT_PARTICLE_STORAGE(IPC)%N_STORAGE_SLOTS
               CALL REALLOCATE_STORAGE_ARRAYS(NOM,3,IPC,N_NEW_STORAGE_SLOTS,NM)
            ENDIF
         ENDDO
      ENDIF

      IF_RECEIVE_PARTICLES: IF (CODE==6 .AND. OMESH_PARTICLES) THEN

         DO IPC=1,N_LAGRANGIAN_CLASSES
            IF (M2%N_PART_ADOPT(IPC)==0) CYCLE
            CNT = 0
            DO N=M4%NLP+1,M4%NLP+M2%N_PART_ADOPT(IPC)
               CNT = CNT + 1
               IBC = LAGRANGIAN_PARTICLE_CLASS(IPC)%SURF_INDEX
               CALL ALLOCATE_STORAGE(NOM,IBC,LPC_INDEX=IPC,LP_INDEX=N,TAG=-1)
               LP=>M4%LAGRANGIAN_PARTICLE(N)
               STORAGE_INDEX_SAVE = LP%STORAGE_INDEX
               M4%PARTICLE_STORAGE(IPC)%REALS(:,STORAGE_INDEX_SAVE)    = M2%ADOPT_PARTICLE_STORAGE(IPC)%REALS(:,CNT)
               M4%PARTICLE_STORAGE(IPC)%INTEGERS(:,STORAGE_INDEX_SAVE) = M2%ADOPT_PARTICLE_STORAGE(IPC)%INTEGERS(:,CNT)
               LP%ARRAY_INDEX = N
               LP%STORAGE_INDEX = STORAGE_INDEX_SAVE
               M4%PARTICLE_STORAGE(IPC)%LOGICALS(:,STORAGE_INDEX_SAVE) = M2%ADOPT_PARTICLE_STORAGE(IPC)%LOGICALS(:,CNT)
               CALL GET_IJK(LP%X,LP%Y,LP%Z,NOM,XI,YJ,ZK,LP%ONE_D%IIG,LP%ONE_D%JJG,LP%ONE_D%KKG)
               IF (LP%INIT_INDEX>0) THEN
                  DO NN=1,N_DEVC
                     IF (DEVICE(NN)%INIT_ID==INITIALIZATION(LP%INIT_INDEX)%ID) THEN
                        DEVICE(NN)%LP_TAG = LP%TAG
                        DEVICE(NN)%PART_CLASS_INDEX = IPC
                     ENDIF
                  ENDDO
               ENDIF
            ENDDO
            M4%NLP = M4%NLP + M2%N_PART_ADOPT(IPC)
         ENDDO

      ENDIF IF_RECEIVE_PARTICLES

      ! Unpack temperature (TMP) only for the case when 3D solid heat conduction is being performed

      IF ((CODE==1.OR.CODE==4) .AND. M2%NIC_R>0 .AND. RNODE/=SNODE .AND.  SOLID_HT3D) THEN
         UNPACK_REAL_RECV_PKG4: DO LL=1,M2%NIC_R
            II1 = M2%IIO_R(LL) ; II2 = II1
            JJ1 = M2%JJO_R(LL) ; JJ2 = JJ1
            KK1 = M2%KKO_R(LL) ; KK2 = KK1
            SELECT CASE(M2%IOR_R(LL))
               CASE(-1) ; II1=M2%IIO_R(LL)   ; II2=II1+1
               CASE( 1) ; II1=M2%IIO_R(LL)-1 ; II2=II1+1
               CASE(-2) ; JJ1=M2%JJO_R(LL)   ; JJ2=JJ1+1
               CASE( 2) ; JJ1=M2%JJO_R(LL)-1 ; JJ2=JJ1+1
               CASE(-3) ; KK1=M2%KKO_R(LL)   ; KK2=KK1+1
               CASE( 3) ; KK1=M2%KKO_R(LL)-1 ; KK2=KK1+1
            END SELECT
            M2%TMP(II1,JJ1,KK1) = M2%REAL_RECV_PKG4(2*(LL-1)+1)
            M2%TMP(II2,JJ2,KK2) = M2%REAL_RECV_PKG4(2*(LL-1)+2)
         ENDDO UNPACK_REAL_RECV_PKG4
      ENDIF

      IF (CODE==14 .AND. M2%NIC_R>0 .AND. RNODE/=SNODE) THEN
            NQT2 = 4
            IF (PREDICTOR) THEN
               PHI_LS_P => M2%PHI1_LS
            ELSE
               PHI_LS_P => M2%PHI_LS
            ENDIF
            UNPACK_REAL_RECV_PKG14: DO LL=1,M2%NIC_R
               II1 = M2%IIO_R(LL)
               JJ1 = M2%JJO_R(LL)
               PHI_LS_P(II1,JJ1) = M2%REAL_RECV_PKG14(NQT2*(LL-1)+1)
               M2%U_LS(II1,JJ1)  = M2%REAL_RECV_PKG14(NQT2*(LL-1)+2)
               M2%V_LS(II1,JJ1)  = M2%REAL_RECV_PKG14(NQT2*(LL-1)+3)
               M2%Z_LS(II1,JJ1)  = M2%REAL_RECV_PKG14(NQT2*(LL-1)+4)
            ENDDO UNPACK_REAL_RECV_PKG14
      ENDIF

   ENDDO RECV_MESH_LOOP

ENDDO SEND_MESH_LOOP

T_USED(11)=T_USED(11) + CURRENT_TIME() - TNOW

END SUBROUTINE MESH_EXCHANGE


SUBROUTINE TIMEOUT(RNAME,NR,RR)

REAL(EB) :: START_TIME,WAIT_TIME
INTEGER, INTENT(IN) :: NR
INTEGER, DIMENSION(:) :: RR,STATUSS(MPI_STATUS_SIZE)
LOGICAL :: FLAG,FLAG2,FLAG3
CHARACTER(*) :: RNAME
INTEGER :: NNN

IF (.NOT.PROFILING) THEN

   ! Normally, PROFILING=F and this branch continually tests the communication and cancels the requests if too much time elapses.

   START_TIME = MPI_WTIME()
   FLAG = .FALSE.
   DO WHILE(.NOT.FLAG)
      CALL MPI_TESTALL(NR,RR(1:NR),FLAG,MPI_STATUSES_IGNORE,IERR)
      WAIT_TIME = MPI_WTIME() - START_TIME
      IF (WAIT_TIME>MPI_TIMEOUT) THEN
         WRITE(LU_ERR,'(A,A,I6,A,A)') TRIM(RNAME),' timed out for MPI process ',MYID,' running on ',PNAME(1:PNAMELEN)
         FLAG = .TRUE.
         DO NNN=1,NR
            CALL MPI_CANCEL(RR(NNN),IERR)
            CALL MPI_TEST(RR(NNN),FLAG2,MPI_STATUS_IGNORE,IERR)
            CALL MPI_TEST_CANCELLED(STATUSS,FLAG3,IERR)
         ENDDO
      ENDIF
   ENDDO

ELSE

   ! If PROFILING=T, do not do MPI_TESTALL because too many calls to this routine swamps the tracing and profiling.

   CALL MPI_WAITALL(NR,RR(1:NR),MPI_STATUSES_IGNORE,IERR)

ENDIF

END SUBROUTINE TIMEOUT


SUBROUTINE DUMP_TIMERS

! Write out the file CHID_cpu.csv containing the timing breakdown of each MPI process.

INTEGER, PARAMETER :: LINE_LENGTH = 5 + (N_TIMERS+1)*11
CHARACTER(LEN=LINE_LENGTH) :: LINE
CHARACTER(LEN=LINE_LENGTH), DIMENSION(0:N_MPI_PROCESSES-1) :: LINE_ARRAY
CHARACTER(30) :: FRMT

! T_USED(1) is the time spent in the main routine; i.e. the time not spent in a subroutine.

T_USED(1) = CURRENT_TIME() - T_USED(1) - SUM(T_USED(2:N_TIMERS))
WRITE(FRMT,'(A,I2.2,A)') '(I5,',N_TIMERS+1,'(",",ES10.3))'
WRITE(LINE,FRMT) MYID,(T_USED(I),I=1,N_TIMERS),SUM(T_USED(1:N_TIMERS))

! All MPI processes except root send their timings to the root process. The root process then writes them out to a file.

IF (MYID>0) THEN
   CALL MPI_SEND(LINE,LINE_LENGTH,MPI_CHARACTER,0,MYID,MPI_COMM_WORLD,IERR)
ELSE
   LINE_ARRAY(0) = LINE
   DO N=1,N_MPI_PROCESSES-1
      CALL MPI_RECV(LINE_ARRAY(N),LINE_LENGTH,MPI_CHARACTER,N,N,MPI_COMM_WORLD,STATUS,IERR)
   ENDDO
   FN_CPU = TRIM(CHID)//'_cpu.csv'
   OPEN(LU_CPU,FILE=FN_CPU,STATUS='REPLACE',FORM='FORMATTED')
   WRITE(LU_CPU,'(A)') 'Rank,MAIN,DIVG,MASS,VELO,PRES,WALL,DUMP,PART,RADI,FIRE,COMM,EVAC,HVAC,GEOM,VEGE,Total T_USED (s)'
   DO N=0,N_MPI_PROCESSES-1
      WRITE(LU_CPU,'(A)') LINE_ARRAY(N)
   ENDDO
   CLOSE(LU_CPU)
ENDIF

END SUBROUTINE DUMP_TIMERS


SUBROUTINE WRITE_STRINGS

! Write character strings out to the .smv file

INTEGER :: N,NOM,N_STRINGS_DUM
CHARACTER(MESH_STRING_LENGTH), ALLOCATABLE, DIMENSION(:) :: STRING_DUM
REAL(EB) :: TNOW

TNOW = CURRENT_TIME()

! All meshes send their STRINGs to node 0

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (MYID>0) THEN
      CALL MPI_SEND(MESHES(NM)%N_STRINGS,1,MPI_INTEGER,0,1,MPI_COMM_WORLD,IERR)
      IF (MESHES(NM)%N_STRINGS>0) CALL MPI_SEND(MESHES(NM)%STRING(1),MESHES(NM)%N_STRINGS*MESH_STRING_LENGTH,MPI_CHARACTER,0,NM, &
                                                MPI_COMM_WORLD,IERR)
   ENDIF
ENDDO

! Node 0 receives the STRINGs and writes them to the .smv file

IF (MYID==0) THEN
   DO N=1,MESHES(1)%N_STRINGS
      WRITE(LU_SMV,'(A)') TRIM(MESHES(1)%STRING(N))
   ENDDO
   OTHER_MESH_LOOP: DO NOM=2,NMESHES
      IF (PROCESS(NOM)>0) THEN
         CALL MPI_RECV(N_STRINGS_DUM,1,MPI_INTEGER,PROCESS(NOM),1,MPI_COMM_WORLD,STATUS,IERR)
         IF (N_STRINGS_DUM>0) THEN
            ALLOCATE(STRING_DUM(N_STRINGS_DUM))
            CALL MPI_RECV(STRING_DUM(1),N_STRINGS_DUM*MESH_STRING_LENGTH, &
            MPI_CHARACTER,PROCESS(NOM),NOM,MPI_COMM_WORLD,STATUS,IERR)
         ENDIF
      ELSE
         N_STRINGS_DUM = MESHES(NOM)%N_STRINGS
         IF (N_STRINGS_DUM>0) THEN
            ALLOCATE(STRING_DUM(N_STRINGS_DUM))
            STRING_DUM(1:N_STRINGS_DUM) = MESHES(NOM)%STRING(1:N_STRINGS_DUM)
         ENDIF
      ENDIF
      DO N=1,N_STRINGS_DUM
         WRITE(LU_SMV,'(A)') TRIM(STRING_DUM(N))
      ENDDO
      IF (ALLOCATED(STRING_DUM)) DEALLOCATE(STRING_DUM)
   ENDDO OTHER_MESH_LOOP
ENDIF

! All STRING arrays are zeroed out

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   MESHES(NM)%N_STRINGS = 0
ENDDO

T_USED(11) = T_USED(11) + CURRENT_TIME() - TNOW
END SUBROUTINE WRITE_STRINGS


SUBROUTINE EXCHANGE_DIAGNOSTICS

INTEGER  :: NOM,DISP
REAL(EB) :: TNOW
TYPE :: MESH_STRUCT
    REAL(EB) :: DBLS(7)
    INTEGER :: INTS(16)
END TYPE MESH_STRUCT
INTEGER  :: LENGTH(2),DTYPES(2)
INTEGER (KIND=MPI_ADDRESS_KIND) STRUCT_DISP(2)
INTEGER  :: MESH_STRUCT_TYPE
TYPE(MESH_STRUCT) :: MESH_SEND, MESH_RECV

TNOW = CURRENT_TIME()

! Gather heat release rates (Q_DOT), mass loss rates (M_DOT), etc., to MPI process 0.

DISP = DISPLS(MYID)+1
REAL_BUFFER_11(        1:        N_Q_DOT,1:NMESHES) = Q_DOT(1:N_Q_DOT,1:NMESHES)
REAL_BUFFER_11(N_Q_DOT+1:N_Q_DOT+N_M_DOT,1:NMESHES) = M_DOT(1:N_M_DOT,1:NMESHES)

CALL MPI_GATHERV(REAL_BUFFER_11(1,DISP),COUNTS_QM_DOT(MYID),MPI_DOUBLE_PRECISION,&
                 REAL_BUFFER_12,COUNTS_QM_DOT,DISPLS_QM_DOT,MPI_DOUBLE_PRECISION,0,MPI_COMM_WORLD,IERR)

IF (MYID==0) THEN
   Q_DOT(1:N_Q_DOT,1:NMESHES) = REAL_BUFFER_12(        1:        N_Q_DOT,1:NMESHES)
   M_DOT(1:N_M_DOT,1:NMESHES) = REAL_BUFFER_12(N_Q_DOT+1:N_Q_DOT+N_M_DOT,1:NMESHES)
ENDIF

! MPI processes greater than 0 send diagnostic data to MPI process 0

LENGTH(1) = 7
LENGTH(2) = 16

STRUCT_DISP(1) = 0
STRUCT_DISP(2) = (STORAGE_SIZE(1.D0) / 8) * 7

DTYPES(1) = MPI_DOUBLE
DTYPES(2) = MPI_INTEGER

CALL MPI_TYPE_CREATE_STRUCT(2, LENGTH, STRUCT_DISP, DTYPES, MESH_STRUCT_TYPE, IERR)
CALL MPI_TYPE_COMMIT(MESH_STRUCT_TYPE, IERR)

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (MYID==0) CYCLE
   MESH_SEND%DBLS(1)  = MESHES(NM)%CFL
   MESH_SEND%DBLS(2)  = MESHES(NM)%DIVMX
   MESH_SEND%DBLS(3)  = MESHES(NM)%DIVMN
   MESH_SEND%DBLS(4)  = MESHES(NM)%RESMAX
   MESH_SEND%DBLS(5)  = MESHES(NM)%POIS_PTB
   MESH_SEND%DBLS(6)  = MESHES(NM)%POIS_ERR
   MESH_SEND%DBLS(7)  = MESHES(NM)%VN
   MESH_SEND%INTS(1)  = MESHES(NM)%ICFL
   MESH_SEND%INTS(2)  = MESHES(NM)%JCFL
   MESH_SEND%INTS(3)  = MESHES(NM)%KCFL
   MESH_SEND%INTS(4)  = MESHES(NM)%IMX
   MESH_SEND%INTS(5)  = MESHES(NM)%JMX
   MESH_SEND%INTS(6)  = MESHES(NM)%KMX
   MESH_SEND%INTS(7)  = MESHES(NM)%IMN
   MESH_SEND%INTS(8)  = MESHES(NM)%JMN
   MESH_SEND%INTS(9)  = MESHES(NM)%KMN
   MESH_SEND%INTS(10)  = MESHES(NM)%IRM
   MESH_SEND%INTS(11)  = MESHES(NM)%JRM
   MESH_SEND%INTS(12)  = MESHES(NM)%KRM
   MESH_SEND%INTS(13)  = MESHES(NM)%I_VN
   MESH_SEND%INTS(14)  = MESHES(NM)%J_VN
   MESH_SEND%INTS(15)  = MESHES(NM)%K_VN
   MESH_SEND%INTS(16)  = MESHES(NM)%NLP
   CALL MPI_SSEND(MESH_SEND, 1, MESH_STRUCT_TYPE, 0, 1, MPI_COMM_WORLD, &
       IERR)
ENDDO

! Node 0 receives various values from all other nodes

DO NOM=1,NMESHES
   IF (PROCESS(NOM)==0 .OR. MYID/=0) CYCLE
   CALL MPI_RECV(MESH_RECV, 1, MESH_STRUCT_TYPE, PROCESS(NOM), 1, &
       MPI_COMM_WORLD, STATUS, IERR)

   MESHES(NOM)%CFL       = MESH_RECV%DBLS(1)
   MESHES(NOM)%DIVMX     = MESH_RECV%DBLS(2)
   MESHES(NOM)%DIVMN     = MESH_RECV%DBLS(3)
   MESHES(NOM)%RESMAX    = MESH_RECV%DBLS(4)
   MESHES(NOM)%POIS_PTB  = MESH_RECV%DBLS(5)
   MESHES(NOM)%POIS_ERR  = MESH_RECV%DBLS(6)
   MESHES(NOM)%VN        = MESH_RECV%DBLS(7)
   MESHES(NOM)%ICFL      = MESH_RECV%INTS(1)
   MESHES(NOM)%JCFL      = MESH_RECV%INTS(2)
   MESHES(NOM)%KCFL      = MESH_RECV%INTS(3)
   MESHES(NOM)%IMX       = MESH_RECV%INTS(4)
   MESHES(NOM)%JMX       = MESH_RECV%INTS(5)
   MESHES(NOM)%KMX       = MESH_RECV%INTS(6)
   MESHES(NOM)%IMN       = MESH_RECV%INTS(7)
   MESHES(NOM)%JMN       = MESH_RECV%INTS(8)
   MESHES(NOM)%KMN       = MESH_RECV%INTS(9)
   MESHES(NOM)%IRM       = MESH_RECV%INTS(10)
   MESHES(NOM)%JRM       = MESH_RECV%INTS(11)
   MESHES(NOM)%KRM       = MESH_RECV%INTS(12)
   MESHES(NOM)%I_VN      = MESH_RECV%INTS(13)
   MESHES(NOM)%J_VN      = MESH_RECV%INTS(14)
   MESHES(NOM)%K_VN      = MESH_RECV%INTS(15)
   MESHES(NOM)%NLP       = MESH_RECV%INTS(16)
ENDDO

CALL MPI_TYPE_FREE(MESH_STRUCT_TYPE, IERR)

T_USED(11) = T_USED(11) + CURRENT_TIME() - TNOW
END SUBROUTINE EXCHANGE_DIAGNOSTICS


SUBROUTINE EXCHANGE_GLOBAL_OUTPUTS

! Gather HRR, mass, and device data to node 0

USE EVAC, ONLY: N_DOORS, N_EXITS, N_ENTRYS, EVAC_DOORS, EVAC_EXITS, EVAC_ENTRYS, EMESH_INDEX
REAL(EB) :: TNOW
INTEGER :: NN,N,I_STATE,I,OP_INDEX,MPI_OP_INDEX,NM,DISP,DIM_FAC
TYPE(DEVICE_TYPE), POINTER :: DV
TYPE(SUBDEVICE_TYPE), POINTER :: SDV
LOGICAL :: NO_NEED_TO_RECV

TNOW = CURRENT_TIME()

IF (ANY(EVACUATION_ONLY) .AND. (ICYC<1 .AND. T>T_BEGIN)) RETURN ! No dumps at the evacuation initialization phase

DISP = DISPLS(MYID)+1

! Gather HRR (Q_DOT) and mass loss rate (M_DOT) integrals to node 0

IF (T>=HRR_CLOCK .AND. N_MPI_PROCESSES>1) THEN
   REAL_BUFFER_11(1:N_Q_DOT,1:NMESHES) = Q_DOT_SUM(1:N_Q_DOT,1:NMESHES)
   REAL_BUFFER_11(N_Q_DOT+1:N_Q_DOT+N_M_DOT,1:NMESHES) = M_DOT_SUM(1:N_M_DOT,1:NMESHES)
   CALL MPI_GATHERV(REAL_BUFFER_11(1,DISP),COUNTS_QM_DOT(MYID),MPI_DOUBLE_PRECISION, &
                    REAL_BUFFER_12,COUNTS_QM_DOT,DISPLS_QM_DOT,MPI_DOUBLE_PRECISION,0,MPI_COMM_WORLD,IERR)
   IF (MYID==0) THEN
      Q_DOT_SUM(1:N_Q_DOT,1:NMESHES) = REAL_BUFFER_12(1:N_Q_DOT,1:NMESHES)
      M_DOT_SUM(1:N_M_DOT,1:NMESHES) = REAL_BUFFER_12(N_Q_DOT+1:N_Q_DOT+N_M_DOT,1:NMESHES)
   ENDIF
ENDIF

! Gather species mass integrals to node 0

IF (T>=MINT_CLOCK .AND. N_MPI_PROCESSES>1) THEN
   REAL_BUFFER_5 = MINT_SUM
   CALL MPI_GATHERV(REAL_BUFFER_5(0,DISP),COUNTS_MASS(MYID),MPI_DOUBLE_PRECISION, &
                    MINT_SUM,COUNTS_MASS,DISPLS_MASS,MPI_DOUBLE_PRECISION,0,MPI_COMM_WORLD,IERR)
ENDIF

! Exchange DEVICE parameters among meshes and dump out DEVICE info after first "gathering" data to node 0

EXCHANGE_DEVICE: IF (N_DEVC>0) THEN

   ! Exchange the CURRENT_STATE and PRIOR_STATE of each DEViCe

   STATE_LOC = .FALSE.  ! _LOC is a temporary array that holds the STATE value for the devices on each node
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      DO N=1,N_DEVC
         DV => DEVICE(N)
         IF (DV%MESH==NM) THEN
            STATE_LOC(N)        = DV%CURRENT_STATE
            STATE_LOC(N+N_DEVC) = DV%PRIOR_STATE
         ENDIF
      ENDDO
   ENDDO
   IF (N_MPI_PROCESSES>1) THEN
      CALL MPI_ALLREDUCE(STATE_LOC(1),STATE_GLB(1),2*N_DEVC,MPI_LOGICAL,MPI_LXOR,MPI_COMM_WORLD,IERR)
   ELSE
      STATE_GLB = STATE_LOC
   ENDIF
   DO N=1,N_DEVC
      DV => DEVICE(N)
      DV%CURRENT_STATE = STATE_GLB(N)
      DV%PRIOR_STATE   = STATE_GLB(N+N_DEVC)
   ENDDO

   ! Dry pipe sprinkler logic

   DEVC_PIPE_OPERATING = 0
   DO N=1,N_DEVC
      IF (DEVICE(N)%PROP_INDEX > 0 .AND.  DEVICE(N)%CURRENT_STATE) THEN
         IF (PROPERTY(DEVICE(N)%PROP_INDEX)%PART_INDEX > 0) DEVC_PIPE_OPERATING(DEVICE(N)%PIPE_INDEX) = &
            DEVC_PIPE_OPERATING(DEVICE(N)%PIPE_INDEX) + 1
      ENDIF
   ENDDO

   ! Each DEViCe has 0 or more SUBDEVICEs. These SUBDEVICEs contain the values of the DEViCe on the meshes controlled
   ! by the copy of the DEViCe controlled by this MPI process. Each MPI process has a copy of every DEViCe, but only
   ! the MPI process that controls the meshes has a copy of the DEViCe for which SUBDEVICEs have been allocated.

   ! In the following loop, for OP_INDEX=1, we add together VALUE_1 and possibly VALUE_2 for all SUBDEVICEs (i.e. meshes)
   ! allocated by the copy of the DEViCe associated with the current MPI process, MYID. Then we do an MPI_ALLREDUCE that
   ! adds the VALUE_1 and VALUE_2 from other SUBDEVICEs allocated by the copies of the DEViCE stored by the other MPI processes.
   ! For OP_INDEX=2 and 3, we take the MIN or MAX of all the VALUEs, along with the MINLOC or MAXLOC.

   OPERATION_LOOP: DO OP_INDEX=1,3
      IF (OP_INDEX==2 .AND. .NOT.MIN_DEVICES_EXIST) CYCLE OPERATION_LOOP
      IF (OP_INDEX==3 .AND. .NOT.MAX_DEVICES_EXIST) CYCLE OPERATION_LOOP
      SELECT CASE(OP_INDEX)
         CASE(1) ; TC_LOC  =  0._EB    ; MPI_OP_INDEX = MPI_SUM    ; DIM_FAC = 3
         CASE(2) ; TC2_LOC =  1.E10_EB ; MPI_OP_INDEX = MPI_MINLOC ; DIM_FAC = 1
         CASE(3) ; TC2_LOC = -1.E10_EB ; MPI_OP_INDEX = MPI_MAXLOC ; DIM_FAC = 1
      END SELECT
      DEVICE_LOOP_1: DO N=1,N_DEVC
         DV => DEVICE(N)
         IF (OP_INDEX==1 .AND. (DV%SPATIAL_STATISTIC(1:3)=='MIN' .OR. DV%SPATIAL_STATISTIC(1:3)=='MAX')) CYCLE
         IF (OP_INDEX==2 .AND.  DV%SPATIAL_STATISTIC(1:3)/='MIN') CYCLE
         IF (OP_INDEX==3 .AND.  DV%SPATIAL_STATISTIC(1:3)/='MAX') CYCLE
         DO NN=1,DV%N_SUBDEVICES
            SDV => DV%SUBDEVICE(NN)
            SELECT CASE(OP_INDEX)
               CASE(1)
                  TC_LOC(N)            = TC_LOC(N)          + SDV%VALUE_1
                  TC_LOC(N+N_DEVC)     = TC_LOC(N+N_DEVC)   + SDV%VALUE_2
                  TC_LOC(N+2*N_DEVC)   = TC_LOC(N+2*N_DEVC) + SDV%VALUE_3
               CASE(2)
                  IF (SDV%VALUE_1<TC2_LOC(1,N)) THEN
                     TC2_LOC(1,N) = SDV%VALUE_1
                     TC2_LOC(2,N) = SDV%VALUE_2
                  ENDIF
               CASE(3)
                  IF (SDV%VALUE_1>TC2_LOC(1,N)) THEN
                     TC2_LOC(1,N) = SDV%VALUE_1
                     TC2_LOC(2,N) = SDV%VALUE_2
                  ENDIF
            END SELECT
         ENDDO
      ENDDO DEVICE_LOOP_1
      IF (N_MPI_PROCESSES>1) THEN
         SELECT CASE(OP_INDEX)
            CASE(1) ; CALL MPI_ALLREDUCE(TC_LOC(1),TC_GLB(1),DIM_FAC*N_DEVC,MPI_DOUBLE_PRECISION,MPI_OP_INDEX,MPI_COMM_WORLD,IERR)
            CASE(2:3) ; CALL MPI_ALLREDUCE(TC2_LOC,TC2_GLB,N_DEVC,MPI_2DOUBLE_PRECISION,MPI_OP_INDEX,MPI_COMM_WORLD,IERR)
         END SELECT
      ELSE
         SELECT CASE(OP_INDEX)
            CASE(1)   ; TC_GLB = TC_LOC
            CASE(2:3) ; TC2_GLB = TC2_LOC
         END SELECT
      ENDIF
      DEVICE_LOOP_2: DO N=1,N_DEVC
         DV => DEVICE(N)
         IF (OP_INDEX==1 .AND. (DV%SPATIAL_STATISTIC(1:3)=='MIN' .OR. DV%SPATIAL_STATISTIC(1:3)=='MAX')) CYCLE
         IF (OP_INDEX==2 .AND.  DV%SPATIAL_STATISTIC(1:3)/='MIN') CYCLE
         IF (OP_INDEX==3 .AND.  DV%SPATIAL_STATISTIC(1:3)/='MAX') CYCLE
         IF (OP_INDEX==1) THEN
            DV%VALUE_1 = TC_GLB(N)
            DV%VALUE_2 = TC_GLB(  N_DEVC+N)
            DV%VALUE_3 = TC_GLB(2*N_DEVC+N)
         ENDIF
         IF (OP_INDEX>1 .AND.  (DV%SPATIAL_STATISTIC=='MIN'.OR.DV%SPATIAL_STATISTIC=='MAX')) THEN
            DV%VALUE_1 = TC2_GLB(1,N)
         ENDIF
         IF (OP_INDEX>1 .AND. (DV%SPATIAL_STATISTIC(1:6)=='MINLOC'.OR.DV%SPATIAL_STATISTIC(1:6)=='MAXLOC')) THEN
            NO_NEED_TO_RECV = .FALSE.
            DO NN=1,DV%N_SUBDEVICES
               SDV => DV%SUBDEVICE(NN)
               IF (PROCESS(SDV%MESH)==MYID) THEN
                  IF (SDV%MESH==NINT(TC2_GLB(2,N))) THEN
                     DV%VALUE_1 = SDV%VALUE_3
                     IF (MYID>0) THEN
                        CALL MPI_SEND(DV%VALUE_1,1,MPI_DOUBLE_PRECISION,0,999,MPI_COMM_WORLD,IERR)
                     ELSE
                        NO_NEED_TO_RECV = .TRUE.
                     ENDIF
                  ENDIF
               ENDIF
            ENDDO
            IF (N_MPI_PROCESSES>1 .AND. MYID==0 .AND. .NOT.NO_NEED_TO_RECV) &
               CALL MPI_RECV(DV%VALUE_1,1,MPI_DOUBLE_PRECISION,MPI_ANY_SOURCE,MPI_ANY_TAG,MPI_COMM_WORLD,STATUS,IERR)
            CALL MPI_BARRIER(MPI_COMM_WORLD,IERR)
            CALL MPI_BCAST(DV%VALUE_1,1,MPI_DOUBLE_PRECISION,0,MPI_COMM_WORLD,IERR)
         ENDIF
      ENDDO DEVICE_LOOP_2
   ENDDO OPERATION_LOOP

ENDIF EXCHANGE_DEVICE

! Perform the temporal operations on the device outputs

CALL UPDATE_DEVICES_2(T,DT)

! Check for change in control function output of device

DEVICE_LOOP: DO N=1,N_DEVC

   DV => DEVICE(N)

   LATCHIF: IF (DV%LATCH) THEN
      IF (DV%INITIAL_STATE .EQV. DV%CURRENT_STATE) THEN
         DEVICE_DIRECTION: IF (DV%TRIP_DIRECTION > 0) THEN
            IF (DV%SMOOTHED_VALUE > DV%SETPOINT) DV%CURRENT_STATE = .NOT.DV%INITIAL_STATE
         ELSE DEVICE_DIRECTION
            IF (DV%SMOOTHED_VALUE < DV%SETPOINT) DV%CURRENT_STATE = .NOT.DV%INITIAL_STATE
         ENDIF DEVICE_DIRECTION
      ENDIF
   ELSE LATCHIF
      DEVICE_DIRECTION2: IF (DV%TRIP_DIRECTION > 0) THEN
         IF ((DV%SMOOTHED_VALUE > DV%SETPOINT) .AND. (DV%CURRENT_STATE .EQV.  DV%INITIAL_STATE)) THEN
            DV%CURRENT_STATE = .NOT.DV%INITIAL_STATE
         ELSEIF ((DV%SMOOTHED_VALUE < DV%SETPOINT) .AND. (DV%CURRENT_STATE .NEQV. DV%INITIAL_STATE)) THEN
            DV%CURRENT_STATE = DV%INITIAL_STATE
         ENDIF
      ELSE DEVICE_DIRECTION2
         IF ((DV%SMOOTHED_VALUE < DV%SETPOINT) .AND. (DV%CURRENT_STATE .EQV.  DV%INITIAL_STATE)) THEN
            DV%CURRENT_STATE = .NOT.DV%INITIAL_STATE
         ELSEIF ((DV%SMOOTHED_VALUE > DV%SETPOINT) .AND. (DV%CURRENT_STATE .NEQV. DV%INITIAL_STATE)) THEN
            DV%CURRENT_STATE = DV%INITIAL_STATE
         ENDIF
      ENDIF DEVICE_DIRECTION2
   ENDIF LATCHIF

   ! If a DEViCe changes state, save the Smokeview file strings and time of state change

   IF (DV%CURRENT_STATE.NEQV.DV%PRIOR_STATE) DV%T_CHANGE = T

   IF (PROCESS(DV%MESH)==MYID .AND. &
       ((DV%CURRENT_STATE.NEQV.DV%PRIOR_STATE) .OR. (ABS(T-T_BEGIN)<SPACING(T).AND..NOT.DV%CURRENT_STATE))) THEN
      M=>MESHES(DV%MESH)
      IF (M%N_STRINGS+2>M%N_STRINGS_MAX) CALL RE_ALLOCATE_STRINGS(DV%MESH)
      I_STATE=0
      IF (DV%CURRENT_STATE) I_STATE=1
      M%N_STRINGS = M%N_STRINGS + 1
      WRITE(M%STRING(M%N_STRINGS),'(A,5X,A,1X)') 'DEVICE_ACT',TRIM(DV%ID)
      M%N_STRINGS = M%N_STRINGS + 1
      WRITE(M%STRING(M%N_STRINGS),'(I6,F10.2,I6)') N,T_BEGIN+(T-T_BEGIN)*TIME_SHRINK_FACTOR,I_STATE
   ENDIF

ENDDO DEVICE_LOOP

! If a door,entr,exit changes state, save the Smokeview file strings and time of state change

EVAC_ONLY: IF (ANY(EVACUATION_ONLY) .AND. MYID==MAX(0,EVAC_PROCESS)) THEN
   I=0  ! Counter for evacuation devices, doors+exits+entrys (evss do not change states)
   DO N=1,N_DOORS
      NM = EVAC_DOORS(N)%IMESH
      IF (.NOT.EVAC_DOORS(N)%SHOW .OR. EMESH_INDEX(NM)==0) CYCLE
      I=I+1
      IF (EVAC_DOORS(N)%IMODE>0 .AND. EVAC_DOORS(N)%IMESH==NM) THEN
         EVAC_DOORS(N)%IMODE=-EVAC_DOORS(N)%IMODE   ! +: change status, -: has already changed status
         M=>MESHES(NM)
         IF (M%N_STRINGS+2>M%N_STRINGS_MAX) CALL RE_ALLOCATE_STRINGS(NM)
         I_STATE=ABS(EVAC_DOORS(N)%IMODE)-1
         M%N_STRINGS = M%N_STRINGS + 1
         WRITE(M%STRING(M%N_STRINGS),'(A,5X,A,1X)') 'DEVICE_ACT',TRIM(EVAC_DOORS(N)%ID)
         M%N_STRINGS = M%N_STRINGS + 1
         WRITE(M%STRING(M%N_STRINGS),'(I6,F10.2,I6)') I+N_DEVC,T,I_STATE
      ENDIF
   ENDDO
   DO N=1,N_EXITS
      NM = EVAC_EXITS(N)%IMESH
      IF (EVAC_EXITS(N)%COUNT_ONLY .OR. .NOT.EVAC_EXITS(N)%SHOW .OR. EMESH_INDEX(NM)==0) CYCLE
      I=I+1
      IF (EVAC_EXITS(N)%IMODE>0 .AND. EVAC_EXITS(N)%IMESH==NM) THEN
         EVAC_EXITS(N)%IMODE=-EVAC_EXITS(N)%IMODE   ! +: change status, -: has already changed status
         M=>MESHES(NM)
         IF (M%N_STRINGS+2>M%N_STRINGS_MAX) CALL RE_ALLOCATE_STRINGS(NM)
         I_STATE=ABS(EVAC_EXITS(N)%IMODE)-1
         M%N_STRINGS = M%N_STRINGS + 1
         WRITE(M%STRING(M%N_STRINGS),'(A,5X,A,1X)') 'DEVICE_ACT',TRIM(EVAC_EXITS(N)%ID)
         M%N_STRINGS = M%N_STRINGS + 1
         WRITE(M%STRING(M%N_STRINGS),'(I6,F10.2,I6)') I+N_DEVC,T,I_STATE
      ENDIF
   ENDDO
   DO N=1,N_ENTRYS
      NM = EVAC_ENTRYS(N)%IMESH
      IF (.NOT.EVAC_ENTRYS(N)%SHOW .OR. EMESH_INDEX(NM)==0) CYCLE
      I=I+1
      IF (EVAC_ENTRYS(N)%IMODE>0 .AND. EVAC_ENTRYS(N)%IMESH==NM) THEN
         EVAC_ENTRYS(N)%IMODE=-EVAC_ENTRYS(N)%IMODE   ! +: change status, -: has already changed status
         M=>MESHES(NM)
         IF (M%N_STRINGS+2>M%N_STRINGS_MAX) CALL RE_ALLOCATE_STRINGS(NM)
         I_STATE=ABS(EVAC_ENTRYS(N)%IMODE)-1
         M%N_STRINGS = M%N_STRINGS + 1
         WRITE(M%STRING(M%N_STRINGS),'(A,5X,A,1X)') 'DEVICE_ACT',TRIM(EVAC_ENTRYS(N)%ID)
         M%N_STRINGS = M%N_STRINGS + 1
         WRITE(M%STRING(M%N_STRINGS),'(I6,F10.2,I6)') I+N_DEVC,T,I_STATE
      ENDIF
   ENDDO
ENDIF EVAC_ONLY

T_USED(7) = T_USED(7) + CURRENT_TIME() - TNOW
END SUBROUTINE EXCHANGE_GLOBAL_OUTPUTS


SUBROUTINE DUMP_GLOBAL_OUTPUTS

! Dump HRR data to CHID_hrr.csv, MASS data to CHID_mass.csv, DEVICE data to _devc.csv

REAL(EB) :: TNOW
TYPE(DEVICE_TYPE), POINTER :: DV

TNOW = CURRENT_TIME()

IF (ANY(EVACUATION_ONLY) .AND. (ICYC<1 .AND. T>T_BEGIN)) RETURN ! No dumps at the evacuation initialization phase

! Dump out HRR info into CHID_hrr.csv

IF (T>=HRR_CLOCK) THEN
   IF (MYID==0) CALL DUMP_HRR(T,DT)
   HRR_CLOCK = HRR_CLOCK + DT_HRR
   Q_DOT_SUM = 0._EB
   M_DOT_SUM = 0._EB
   T_LAST_DUMP_HRR = T
ENDIF

! Dump unstructured geometry and boundary element info

IF (N_FACE>0 .AND. T>=GEOM_CLOCK) THEN
   IF (MYID==0) THEN
      CALL DUMP_GEOM(T)
   ENDIF
   GEOM_CLOCK = GEOM_CLOCK + DT_GEOM
ENDIF

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This block is deprecated, but needs to be removed just prior to FDS 7 release
! to avoid RESTART issues in v6
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
IF (N_GEOM>0 .AND. T>=BNDC_CLOCK) THEN
   !IF (MYID==0) CALL DUMP_BNDC(T)
   BNDC_CLOCK = BNDC_CLOCK + DT_BNDC
ENDIF

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

! Dump out Evac info

IF (MYID==MAX(0,EVAC_PROCESS)) CALL EVAC_CSV(T)

! Dump out mass info into CHID_mass.csv

IF (T>=MINT_CLOCK) THEN
   IF (MYID==0) CALL DUMP_MASS(T,DT)
   MINT_CLOCK = MINT_CLOCK + DT_MASS
   MINT_SUM   = 0._EB
   T_LAST_DUMP_MASS = T
ENDIF

! Dump device info into CHID_devc.csv

IF (T>=DEVC_CLOCK .AND. N_DEVC>0) THEN

   ! Exchange histogram info

   DO N=1,N_DEVC
      DV => DEVICE(N)
      IF (.NOT.PROPERTY(DV%PROP_INDEX)%HISTOGRAM) CYCLE
      IF (PROCESS(DV%MESH)==MYID .AND. MYID>0) CALL MPI_SEND(DV%HISTOGRAM_COUNTS(1), &
          PROPERTY(DV%PROP_INDEX)%HISTOGRAM_NBINS,MPI_DOUBLE_PRECISION,0,DV%MESH,MPI_COMM_WORLD,IERR)
      IF (PROCESS(DV%MESH)>0 .AND. MYID==0) CALL MPI_RECV(DV%HISTOGRAM_COUNTS(1), &
          PROPERTY(DV%PROP_INDEX)%HISTOGRAM_NBINS,MPI_DOUBLE_PRECISION,PROCESS(DV%MESH),DV%MESH,MPI_COMM_WORLD,STATUS,IERR)
   ENDDO

   ! Dump the device output to file

   IF (MINVAL(DEVICE(1:N_DEVC)%TIME_INTERVAL)>0._EB) THEN
      IF (MYID==0) CALL DUMP_DEVICES(T)
      DEVC_CLOCK = MIN(DEVC_CLOCK + DT_DEVC, T_END)
      DEVICE_LOOP: DO N=1,N_DEVC
         DV => DEVICE(N)
         IF (T>DV%STATISTICS_END) CYCLE
         IF (DV%NO_UPDATE_DEVC_INDEX>0) THEN
            IF (DEVICE(DV%NO_UPDATE_DEVC_INDEX)%CURRENT_STATE) CYCLE DEVICE_LOOP
         ELSEIF (DV%NO_UPDATE_CTRL_INDEX>0) THEN
            IF (CONTROL(DV%NO_UPDATE_CTRL_INDEX)%CURRENT_STATE) CYCLE DEVICE_LOOP
         ENDIF
         DV%VALUE = 0._EB
         DV%TIME_INTERVAL = 0._EB
      ENDDO DEVICE_LOOP
   ENDIF

ENDIF

! Dump CONTROL info. No gathering required as CONTROL is updated on all meshes

IF (T>=CTRL_CLOCK .AND. N_CTRL>0) THEN
   IF (MYID==0) CALL DUMP_CONTROLS(T)
   CTRL_CLOCK = CTRL_CLOCK + DT_CTRL
ENDIF

! Dump CPU time

IF (T>=CPU_CLOCK) THEN
   CALL DUMP_TIMERS
   CPU_CLOCK = CPU_CLOCK + DT_CPU
ENDIF

T_USED(7) = T_USED(7) + CURRENT_TIME() - TNOW
END SUBROUTINE DUMP_GLOBAL_OUTPUTS


SUBROUTINE INITIALIZE_EVAC

! Initialize evacuation meshes

DO NM=1,NMESHES
   IF (N_MPI_PROCESSES>1 .AND. MYID==EVAC_PROCESS .AND. .NOT.EVACUATION_ONLY(NM)) THEN
      M=>MESHES(NM)
      !EVACUATION: SOLID, CELL_INDEX, OBST_INDEX_C, OBSTRUCTION are allocated in READ_OBST for the evac process.
      ALLOCATE(M%ZZ(0:M%IBP1,0:M%JBP1,0:M%KBP1,N_TRACKED_SPECIES),STAT=IZERO)
      CALL ChkMemErr('MAIN','Evac ZZ',IZERO)
      M%ZZ=0._EB
      ALLOCATE(M%RHO(0:M%IBP1,0:M%JBP1,0:M%KBP1),STAT=IZERO)
      CALL ChkMemErr('MAIN','Evac RHO',IZERO)
      M%RHO=RHOA
      ALLOCATE(M%RSUM(0:M%IBP1,0:M%JBP1,0:M%KBP1),STAT=IZERO)
      CALL ChkMemErr('MAIN','Evac RSUM',IZERO)
      M%RSUM=RSUM0
      ALLOCATE(M%TMP(0:M%IBP1,0:M%JBP1,0:M%KBP1),STAT=IZERO)
      CALL ChkMemErr('MAIN','Evac TMP',IZERO)
      M%TMP=TMPA
      ALLOCATE(M%UII(0:M%IBP1,0:M%JBP1,0:M%KBP1),STAT=IZERO)
      CALL ChkMemErr('MAIN','Evac UII',IZERO)
      M%UII=4._EB*SIGMA*TMPA4
   ENDIF
   IF (PROCESS(NM)/=MYID) CYCLE
   IF (EVACUATION_ONLY(NM).AND.EMESH_INDEX(NM)>0) PART_CLOCK(NM) = T_EVAC + DT_PART
   IF (MYID/=MAX(0,EVAC_PROCESS)) CYCLE
   IF (ANY(EVACUATION_ONLY)) CALL INITIALIZE_EVACUATION(NM)
   IF (EVACUATION_ONLY(NM).AND.EMESH_INDEX(NM)>0) CALL DUMP_EVAC(T_EVAC,NM)
ENDDO
IF (ANY(EVACUATION_ONLY) .AND. .NOT.RESTART) ICYC = -EVAC_TIME_ITERATIONS
DT_EVAC=DT

END SUBROUTINE INITIALIZE_EVAC

SUBROUTINE INIT_EVAC_DUMPS

! Initialize evacuation dumps

REAL(EB) :: T_TMP

IF (.NOT.ANY(EVACUATION_ONLY)) RETURN ! No evacuation

IF (RESTART) THEN
   T_TMP = T
   T_EVAC_SAVE = T_TMP
ELSE
   T_EVAC  = - EVAC_DT_FLOWFIELD*EVAC_TIME_ITERATIONS + T_BEGIN
   T_EVAC_SAVE = T_EVAC
   T_TMP = T_EVAC
END IF
IF (.NOT.ANY(EVACUATION_SKIP)) RETURN ! No main evacuation meshes
IF (N_MPI_PROCESSES==1 .OR. (N_MPI_PROCESSES>1 .AND. MYID==EVAC_PROCESS))  CALL INITIALIZE_EVAC_DUMPS(T_TMP,T_EVAC_SAVE)

END SUBROUTINE INIT_EVAC_DUMPS


SUBROUTINE EVAC_CSV(T)

! Dump out Evac info

REAL(EB), INTENT(IN) :: T

IF (T>=EVAC_CLOCK .AND. ANY(EVACUATION_ONLY)) THEN
   CALL DUMP_EVAC_CSV(T)
   EVAC_CLOCK = EVAC_CLOCK + DT_HRR
ENDIF

END SUBROUTINE EVAC_CSV


SUBROUTINE EVAC_EXCHANGE

LOGICAL EXCHANGE_EVACUATION
INTEGER NM, II, IVENT, I, J, EMESH, JJ, N_END

! Fire mesh information ==> Evac meshes

IF (.NOT. ANY(EVACUATION_ONLY)) RETURN
IF (N_MPI_PROCESSES>1 .AND. MYID /= EVAC_PROCESS) CALL EVAC_MESH_EXCHANGE(T_EVAC,T_EVAC_SAVE,I_EVAC,ICYC,EXCHANGE_EVACUATION,1)
IF (N_MPI_PROCESSES==1 .OR. (N_MPI_PROCESSES>1 .AND. MYID==EVAC_PROCESS)) &
     CALL EVAC_MESH_EXCHANGE(T_EVAC,T_EVAC_SAVE,I_EVAC,ICYC,EXCHANGE_EVACUATION,2)

! Update evacuation devices

DO NM=1,NMESHES
   IF (.NOT.EVACUATION_ONLY(NM).OR.EMESH_INDEX(NM)==0.OR.EVACUATION_SKIP(NM)) CYCLE
   IF (MYID/=MAX(0,EVAC_PROCESS)) CYCLE
   CALL UPDATE_GLOBAL_OUTPUTS(T,DT,NM)
ENDDO

! Save the evacuation flow fields to the arrays U_EVAC and V_EVAC

N_END = N_EXITS - N_CO_EXITS + N_DOORS
DO NM = 1, NMESHES
   IF (.NOT.EVACUATION_ONLY(NM).OR.EMESH_INDEX(NM)==0.OR.EVACUATION_SKIP(NM)) CYCLE
   IF (MYID /= MAX(0,EVAC_PROCESS)) CYCLE
   II = EVAC_TIME_ITERATIONS / MAXVAL(EMESH_NFIELDS)
   IF (MOD(ABS(ICYC),II)==0) THEN
      IVENT = (ABS(ICYC))/II + 1
      LOOP_EXITS: DO JJ = 1, N_END
         IF (EMESH_EXITS(JJ)%MAINMESH == NM .AND. EMESH_EXITS(JJ)%I_DOORS_EMESH == IVENT) THEN
            EMESH = EMESH_EXITS(JJ)%EMESH
            DO J = 0, EMESH_IJK(2,EMESH) + 1
               DO I = 0, EMESH_IJK(1,EMESH) + 1
                  ! FB is the EFF file precision. Convert to FB here so that EFF read calculation gives
                  ! exactly the same results as EFF write calculation for the agents.
                  IF (MESHES(NM)%PRESSURE_ZONE(I,J,1)>0) THEN
                     EMESH_EXITS(JJ)%U_EVAC(I,J) = REAL(MESHES(NM)%U(I,J,1),FB)
                     EMESH_EXITS(JJ)%V_EVAC(I,J) = REAL(MESHES(NM)%V(I,J,1),FB)
                  ELSE
                     EMESH_EXITS(JJ)%U_EVAC(I,J) = 0.0_FB
                     EMESH_EXITS(JJ)%V_EVAC(I,J) = 0.0_FB
                  END IF
               END DO
            END DO
            EXIT LOOP_EXITS
         END IF
      END DO LOOP_EXITS
   END IF

ENDDO

END SUBROUTINE EVAC_EXCHANGE


SUBROUTINE EVAC_PRESSURE_ITERATION_SCHEME

! Evacuation flow field calculation

INTEGER :: N

COMPUTE_PRESSURE_LOOP: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (EVACUATION_SKIP(NM).OR..NOT.EVACUATION_ONLY(NM)) CYCLE COMPUTE_PRESSURE_LOOP
   PRESSURE_ITERATION_LOOP: DO N=1,EVAC_PRESSURE_ITERATIONS
      CALL NO_FLUX(DT,NM)
      MESHES(NM)%FVZ = 0._EB
      CALL PRESSURE_SOLVER_COMPUTE_RHS(T,NM)
      CALL PRESSURE_SOLVER_FFT(NM)
      CALL PRESSURE_SOLVER_CHECK_RESIDUALS(NM)
   ENDDO PRESSURE_ITERATION_LOOP
ENDDO COMPUTE_PRESSURE_LOOP

END SUBROUTINE EVAC_PRESSURE_ITERATION_SCHEME


SUBROUTINE EVAC_MAIN_LOOP
USE RADCONS, ONLY: TIME_STEP_INCREMENT

! Call the evacuation routine and adjust the time steps for the evacuation meshes

REAL(EB) :: T_FIRE, EVAC_DT, DT_TMP
INTEGER :: II

EVACUATION_SKIP=.FALSE. ! Do not skip the flow calculation

EVAC_DT = EVAC_DT_STEADY_STATE
T_FIRE = T_EVAC + EVAC_DT
IF (ICYC < 1) EVAC_DT = EVAC_DT_FLOWFIELD
IF (ICYC < 1) DT = EVAC_DT
IF (ICYC < 1) DT_NEW = DT_EVAC
IF (ICYC == 1) DT = DT_EVAC ! Initial fire dt that was read in
IF (ICYC == 1) T  = T_BEGIN ! Initial fire t  that was read in
IF (ICYC == 1) T_EVAC = T_BEGIN - 0.1_EB*MIN(EVAC_DT_FLOWFIELD,EVAC_DT_STEADY_STATE)
IF (ICYC > 0) T_FIRE  = T

DT_TMP = DT
IF ((T+DT)>=T_END) DT_TMP = MAX(MIN(EVAC_DT_STEADY_STATE,T_END-T_EVAC),1.E-10_EB)
IF (ICYC > 0) EVAC_DT = DT_TMP

DO NM = 1, NMESHES
   IF (EVACUATION_ONLY(NM).AND.EMESH_INDEX(NM)==0) EVACUATION_SKIP(NM) = .TRUE.
   IF (EVACUATION_ONLY(NM).AND.EMESH_INDEX(NM)>0) DT_NEW(NM) = EVAC_DT
END DO
IF (ICYC <= 0) THEN
   DO NM = 1, NMESHES
      IF (.NOT.EVACUATION_ONLY(NM)) EVACUATION_SKIP(NM) = .TRUE.  ! Be sure that no fire meshes are updated for icyc < 0
   END DO
ENDIF
IF (.NOT.ALL(EVACUATION_ONLY) .AND. RADIATION .AND. ICYC > 0) THEN
   DO NM = 1, NMESHES
      IF (.NOT.EVACUATION_ONLY(NM)) CYCLE
      IF (MOD(MESHES(NM)%RAD_CALL_COUNTER,TIME_STEP_INCREMENT)==0 .OR. ICYC==1) THEN
         EXCHANGE_RADIATION = .TRUE.
      ELSE
         EXCHANGE_RADIATION = .FALSE.
      ENDIF
      MESHES(NM)%RAD_CALL_COUNTER  = MESHES(NM)%RAD_CALL_COUNTER + 1
   ENDDO
ENDIF

EVAC_TIME_STEP_LOOP: DO WHILE (T_EVAC < T_FIRE)
   T_EVAC = T_EVAC + EVAC_DT
   IF (N_MPI_PROCESSES==1 .OR. (N_MPI_PROCESSES>1 .AND. MYID==EVAC_PROCESS)) CALL PREPARE_TO_EVACUATE(ICYC)
   DO NM = 1, NMESHES
      IF (EVACUATION_ONLY(NM)) THEN
         EVACUATION_SKIP(NM)  = .TRUE.
         IF (ICYC <= 1 .AND. .NOT.BTEST(I_EVAC, 2)) THEN
            IF (ICYC <= 0 .AND. EMESH_INDEX(NM)>0) THEN
               II = EVAC_TIME_ITERATIONS / MAXVAL(EMESH_NFIELDS)
               IF ((ABS(ICYC)+1) <= EMESH_NFIELDS(EMESH_INDEX(NM))*II) THEN
                  EVACUATION_SKIP(NM) = .FALSE.
               ELSE
                  EVACUATION_SKIP(NM) = .TRUE.
               END IF
               DIAGNOSTICS = .FALSE.
            END IF
            !
            IF (ICYC <= 0) T = T_EVAC + EVAC_DT_FLOWFIELD*EVAC_TIME_ITERATIONS - EVAC_DT_FLOWFIELD
         ENDIF
         IF (ICYC <= 1 .AND. BTEST(I_EVAC, 2)) THEN
            IF (ICYC <= 0 .AND. EMESH_INDEX(NM)>0) THEN
               EVACUATION_SKIP(NM) = .TRUE.
               DIAGNOSTICS = .FALSE.
            END IF
            IF (ICYC <= 0) T = T_EVAC + EVAC_DT_FLOWFIELD*EVAC_TIME_ITERATIONS - EVAC_DT_FLOWFIELD
         ENDIF
         IF (EMESH_INDEX(NM)==0) THEN
            VELOCITY_ERROR_MAX_LOC(:,NM) = 1
            VELOCITY_ERROR_MAX(NM) = 0._EB
            MESHES(NM)%POIS_ERR = 0.0_EB
            MESHES(NM)%POIS_PTB = 0.0_EB
            MESHES(NM)%RESMAX = 0.0_EB
            MESHES(NM)%CFL = 0.0_EB
            MESHES(NM)%ICFL = 0; MESHES(NM)%JCFL = 0; MESHES(NM)%KCFL = 0
            MESHES(NM)%DIVMX = 0.0_EB
            MESHES(NM)%IMX = 0; MESHES(NM)%JMX = 0; MESHES(NM)%KMX = 0
            MESHES(NM)%DIVMN = 0.0_EB
            MESHES(NM)%IMN = 0; MESHES(NM)%JMN = 0; MESHES(NM)%KMN = 0
         END IF
         IF (EMESH_INDEX(NM)>0) THEN
            IF (PROCESS(NM)==MYID .AND. STOP_STATUS==NO_STOP) CALL EVACUATE_HUMANS(T_EVAC,DT_TMP,NM,ICYC)
            IF (T_EVAC >= PART_CLOCK(NM)) THEN
               IF (PROCESS(NM)==MYID) CALL DUMP_EVAC(T_EVAC, NM)
               DO
                  PART_CLOCK(NM) = PART_CLOCK(NM) + DT_PART
                  IF (PART_CLOCK(NM) >= T_EVAC) EXIT
               ENDDO
            ENDIF
         ENDIF
      ENDIF
   ENDDO
   IF (ICYC < 1) EXIT EVAC_TIME_STEP_LOOP
   IF (N_MPI_PROCESSES==1 .OR. (N_MPI_PROCESSES>1 .AND. MYID==EVAC_PROCESS)) CALL CLEAN_AFTER_EVACUATE(ICYC, I_EVAC)
ENDDO EVAC_TIME_STEP_LOOP
IF (ICYC < 1 .AND. MYID==0) THEN
   ! Write the diagnostic information for the evacuation mesh initialization time steps
   II = EVAC_TIME_ITERATIONS / MAXVAL(EMESH_NFIELDS)
   IF (MOD(ABS(ICYC)+1,II) == 0 .OR. ABS(ICYC)+1 == EVAC_TIME_ITERATIONS) THEN
      WRITE(LU_ERR,'(1X,A,I7,A,F10.3,A)')  'Time Step:',ICYC,',    Evacuation Initialization Time:',T_EVAC,' s'
   END IF
END IF

END SUBROUTINE EVAC_MAIN_LOOP


SUBROUTINE EXCHANGE_HVAC_BC

! Exchange information mesh to mesh needed for performing the HVAC computation

USE HVAC_ROUTINES, ONLY: NODE_H,NODE_P,NODE_RHO,NODE_TMP,NODE_X,NODE_Y,NODE_Z,NODE_ZZ
INTEGER :: NN
REAL(EB) :: TNOW

TNOW = CURRENT_TIME()

! Pack HVAC values into REAL_BUFFER_6

REAL_BUFFER_6(              1:  N_DUCTNODES,:) = NODE_H(1:N_DUCTNODES,:)
REAL_BUFFER_6(  N_DUCTNODES+1:2*N_DUCTNODES,:) = NODE_P(1:N_DUCTNODES,:)
REAL_BUFFER_6(2*N_DUCTNODES+1:3*N_DUCTNODES,:) = NODE_RHO(1:N_DUCTNODES,:)
REAL_BUFFER_6(3*N_DUCTNODES+1:4*N_DUCTNODES,:) = NODE_TMP(1:N_DUCTNODES,:)
REAL_BUFFER_6(4*N_DUCTNODES+1:5*N_DUCTNODES,:) = NODE_X(1:N_DUCTNODES,:)
REAL_BUFFER_6(5*N_DUCTNODES+1:6*N_DUCTNODES,:) = NODE_Y(1:N_DUCTNODES,:)
REAL_BUFFER_6(6*N_DUCTNODES+1:7*N_DUCTNODES,:) = NODE_Z(1:N_DUCTNODES,:)
REAL_BUFFER_6(7*N_DUCTNODES+1:8*N_DUCTNODES,:) = NODE_AREA(1:N_DUCTNODES,:)
REAL_BUFFER_6(8*N_DUCTNODES+1:9*N_DUCTNODES,:) = NODE_ZONE(1:N_DUCTNODES,:)
NN = 8
DO N=1,N_TRACKED_SPECIES
   NN = NN + 1
   REAL_BUFFER_6(NN*N_DUCTNODES+1:(NN+1)*N_DUCTNODES,:) = NODE_ZZ(1:N_DUCTNODES,N,:)
ENDDO

CALL MPI_GATHERV(REAL_BUFFER_6(1,DISPLS(MYID)+1),COUNTS_HVAC(MYID),MPI_DOUBLE_PRECISION, &
                 REAL_BUFFER_8,COUNTS_HVAC,DISPLS_HVAC,MPI_DOUBLE_PRECISION,0,MPI_COMM_WORLD,IERR)

! Unpack HVAC values on MPI process 0

IF (MYID==0) THEN
   NODE_H(1:N_DUCTNODES,:)    =     REAL_BUFFER_8(              1:  N_DUCTNODES,:)
   NODE_P(1:N_DUCTNODES,:)    =     REAL_BUFFER_8(  N_DUCTNODES+1:2*N_DUCTNODES,:)
   NODE_RHO(1:N_DUCTNODES,:)  =     REAL_BUFFER_8(2*N_DUCTNODES+1:3*N_DUCTNODES,:)
   NODE_TMP(1:N_DUCTNODES,:)  =     REAL_BUFFER_8(3*N_DUCTNODES+1:4*N_DUCTNODES,:)
   NODE_X(1:N_DUCTNODES,:)    =     REAL_BUFFER_8(4*N_DUCTNODES+1:5*N_DUCTNODES,:)
   NODE_Y(1:N_DUCTNODES,:)    =     REAL_BUFFER_8(5*N_DUCTNODES+1:6*N_DUCTNODES,:)
   NODE_Z(1:N_DUCTNODES,:)    =     REAL_BUFFER_8(6*N_DUCTNODES+1:7*N_DUCTNODES,:)
   NODE_AREA(1:N_DUCTNODES,:) =     REAL_BUFFER_8(7*N_DUCTNODES+1:8*N_DUCTNODES,:)
   NODE_ZONE(1:N_DUCTNODES,:) = INT(REAL_BUFFER_8(8*N_DUCTNODES+1:9*N_DUCTNODES,:))
   NN = 8
   DO N=1,N_TRACKED_SPECIES
      NN = NN + 1
      NODE_ZZ(1:N_DUCTNODES,N,:) = REAL_BUFFER_8(NN*N_DUCTNODES+1:(NN+1)*N_DUCTNODES,:)
   ENDDO
ENDIF

T_USED(11)=T_USED(11) + CURRENT_TIME() - TNOW
END SUBROUTINE EXCHANGE_HVAC_BC


SUBROUTINE EXCHANGE_HVAC_SOLUTION

! Exchange information mesh to mesh needed for performing the HVAC computation

USE HVAC_ROUTINES, ONLY: NODE_AREA_EX,NODE_TMP_EX,NODE_ZZ_EX,DUCT_MF
REAL(EB) :: TNOW
INTEGER :: NN

TNOW = CURRENT_TIME()

REAL_BUFFER_1(            1:  N_DUCTNODES) = NODE_AREA_EX(1:N_DUCTNODES)
REAL_BUFFER_1(N_DUCTNODES+1:2*N_DUCTNODES) = NODE_TMP_EX(1:N_DUCTNODES)
NN = 1
DO N=1,N_TRACKED_SPECIES
   NN = NN + 1
   REAL_BUFFER_1(NN*N_DUCTNODES+1:(NN+1)*N_DUCTNODES) = NODE_ZZ_EX(1:N_DUCTNODES,N)
ENDDO
REAL_BUFFER_1((2+N_TRACKED_SPECIES)*N_DUCTNODES+1:(2+N_TRACKED_SPECIES)*N_DUCTNODES+N_DUCTS) = DUCT_MF(1:N_DUCTS)

CALL MPI_BCAST(REAL_BUFFER_1,(2+N_TRACKED_SPECIES)*N_DUCTNODES+N_DUCTS,MPI_DOUBLE_PRECISION,0,MPI_COMM_WORLD,IERR)

NODE_AREA_EX(1:N_DUCTNODES) = REAL_BUFFER_1(            1:  N_DUCTNODES)
NODE_TMP_EX(1:N_DUCTNODES)  = REAL_BUFFER_1(N_DUCTNODES+1:2*N_DUCTNODES)
NN = 1
DO N=1,N_TRACKED_SPECIES
   NN = NN + 1
   NODE_ZZ_EX(1:N_DUCTNODES,N) = REAL_BUFFER_1(NN*N_DUCTNODES+1:(NN+1)*N_DUCTNODES)
ENDDO
DUCT_MF(1:N_DUCTS) = REAL_BUFFER_1((2+N_TRACKED_SPECIES)*N_DUCTNODES+1:(2+N_TRACKED_SPECIES)*N_DUCTNODES+N_DUCTS)

T_USED(11)=T_USED(11) + CURRENT_TIME() - TNOW
END SUBROUTINE EXCHANGE_HVAC_SOLUTION


!> \brief Check to see if any FREEZE_VELOCITY=T and any SOLID_PHASE_ONLY=T

SUBROUTINE CHECK_FREEZE_VELOCITY_STATUS

CALL MPI_ALLREDUCE(MPI_IN_PLACE,FREEZE_VELOCITY ,INTEGER_ONE,MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,IERR)
CALL MPI_ALLREDUCE(MPI_IN_PLACE,SOLID_PHASE_ONLY,INTEGER_ONE,MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,IERR)
IF (FREEZE_VELOCITY) CHECK_FREEZE_VELOCITY = .FALSE.

END SUBROUTINE CHECK_FREEZE_VELOCITY_STATUS


SUBROUTINE GET_INFO (REVISION,REVISION_DATE,COMPILE_DATE)
CHARACTER(LEN=255), INTENT(OUT) :: REVISION, REVISION_DATE, COMPILE_DATE

! Unlike svn, the revisioning system git does not perform keyword substitution.
! To perform this function,  a script named expand_file is called before FDS is
! built that expands the following keywords ($Revision, $RevisionDate and
! $CompileDate) with their proper values. Another script named contract_file is
! called after FDS is built to return these keywords back to their original
! values (so the revisioning system will not think this file has changed).

CHARACTER(255), PARAMETER :: GREVISION='$Revision$'
CHARACTER(255), PARAMETER :: GREVISION_DATE='$RevisionDate: unknown $'
CHARACTER(255), PARAMETER :: GCOMPILE_DATE='$CompileDate: unknown $'

WRITE(REVISION,'(A)')      GREVISION(INDEX(GREVISION,':')+2:LEN_TRIM(GREVISION)-2)
WRITE(REVISION_DATE,'(A)') GREVISION_DATE(INDEX(GREVISION_DATE,':')+2:LEN_TRIM(GREVISION_DATE)-2)
WRITE(COMPILE_DATE,'(A)')  GCOMPILE_DATE(INDEX(GCOMPILE_DATE,':')+2:LEN_TRIM(GCOMPILE_DATE)-2)
RETURN
END SUBROUTINE GET_INFO

END PROGRAM FDS
