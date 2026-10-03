--[[
	ZZ_Melee.lua -- general-purpose melee overhaul for the player Terminator.

	  LEFT HAND   which part of the left-hand weapon rides the left
	              controller, with a grip per weapon class.
	  CANNED SWING the flat game's attack animation no longer swings the
	              arms, and a landed hit no longer shakes the camera.
	  HIT TRACE   the game's own melee sweep runs from the visible weapon.
	  FORCE SWORD the blade's fire only burns while LT is held, with a light
	              on the blade and an ignition/burn sound.
	  IMPALE      a point-first thrust skewers a stealer: killed whole, the
	              body hangs off the blade until a sharp flick throws it.
	  REVERSE     a brush of the left thumbrest turns the sword round in the
	              fist (and back); a pommel-first bash stuns a stealer hard.
	  ARM IK      forearm and upper arm hang between the hand and the
	              shoulder under the pauldron (two-bone solve): left with the
	              sword drawn, right whenever the gun arm is frozen (bolter
	              drawn or holstered); chest and pauldrons follow the body,
	              not the nod.
	  LEFT INPUT  swing = light attack, swing + LT = heavy, LB = parry --
	              moved here from MainHandler 2026-09-29 -- plus LB behind
	              the head to sheathe a mesh weapon, and a bare hand (or the
	              Power Fist) that grabs stealers and punches (ZZ_Grab).
	              LT is otherwise free, so "hold LT to ignite, swing to
	              strike" is one gesture. See the LI config block and NOTES.
]]

--==========================================================================
-- CONFIG
--==========================================================================

local ENABLED = true

-- LEFT HAND ---------------------------------------------------------------
-- One entry per left-hand weapon class:
--   attach = "mesh"  the weapon's own MeleeWeapon mesh (sword, axe, shield)
--   attach = "arm"   pawn.LArm, for weapons that ARE the arm -- equipping
--                    them swaps LArm's mesh (Power Fist, Lightning Claw)
-- quat/loc are UEVR's own units, copied verbatim from a uobjecthook
-- *_mc_state.json (rotation_offset w,x,y,z and location_offset x,y,z), so a
-- grip tuned in UEVR's attach UI can be pasted straight in. rot is the
-- alternative: set_rotation_offset's three slots in degrees, which
-- CameraManager measured as (PITCH, ROLL, YAW).
local LEFT_HAND_ENABLED = true

-- true = write each weapon's grip once when it is equipped, then leave it
-- alone so it can be adjusted in UEVR's attach UI. Save there, then copy the
-- JSON numbers into LEFT_WEAPONS and set this back to false.
local TUNE_LEFT_HAND = false

-- A mesh weapon's own mesh rides the controller, but LArm is still visible
-- and, left alone, is posed by the body animation -- whose aim UEVR slaves
-- to the RIGHT controller, so the left arm tracked the wrong hand. armGrip
-- puts LArm on the left controller as well, so arm and weapon move together.
-- Starting point is the measured "L_Hand on the controller" value, with the
-- rotation borrowed from the tuned fist; tune loc/rot until the hand meets
-- the hilt. HAND_LOCK keeps it steady through the walk cycle.
-- Tuned in UEVR's own attach UI and copied from it, so handLock is off: the
-- hand-lock correction would shift loc away from what was dialled in.
-- PositionOffset maps across unchanged (same slots, same cm). RotationOffset
-- does NOT: UEVR shows it in RADIANS and rot here is DEGREES, so the GUI's
-- (0.420, 0.841, 0.244) becomes (24.06, 48.19, 13.98) -- multiply by 57.2958.
local SWORD_ARM_GRIP = {
	attach = "arm",
	handLock = false,
	-- Straight from UEVR's own save, uobjecthook/17809686142274175108
	-- (Acknowledged Pawn > Components > SkeletalMeshComponent LArm), written
	-- by "Save state" 2026-09-28 22:42. A saved quat beats reading degrees
	-- off the GUI: it is passed through as a UEVR_Quaternionf with no
	-- conversion, so nothing is lost to rounding.
	loc  = { 33.963043, 162.666611, -60.101002 },
	quat = { -0.838725, -0.168545, 0.517379, 0.021259 },   -- w, x, y, z
}

-- Straight from UEVR's own save, uobjecthook/15426945207052222384
-- (Acknowledged Pawn > Properties > LeftWeapon > Properties > MeleeWeapon),
-- written by "Save state" 2026-09-28 23:07. Exact, unlike degrees read off
-- the GUI. A mesh grip never gets the hand-lock correction, so loc is used
-- exactly as entered. Note setGripRotation prefers quat over rot, so do not
-- leave a stale rot beside it -- it would be silently ignored.
local SWORD_GRIP = {
	attach = "mesh",
	loc  = { 12.202845, 1.876517, 6.017136 },
	quat = { -0.670717, -0.194240, 0.711343, -0.079999 },   -- w, x, y, z
	armGrip = SWORD_ARM_GRIP,
}

-- Measured 2026-09-28 with the Power Fist on: puts the hand bone (socket
-- L_Hand, where the real hand sits inside the gauntlet) on the controller.
-- It is the negative of L_Hand's position in LArm's own frame, in the
-- offset's (left, down, forward) slots. CameraManager's old untuned values
-- (-40, 160, -50) left the fist ~31 cm left of the controller. No view-pitch
-- staging (followViewPitch): the fist follows the controller and nothing else.
-- Forward trimmed 11.6 -> 1.6 in-headset: the measured fit sat too far ahead.
local ARM_GRIP = {
	attach = "arm",
	loc = { -60.3, 150.1, 15.0 },
	rot = { -50.0, 0.0, 55.0 },
}

-- Untuned entries share a grip until they get their own.
local LEFT_WEAPONS = {
	BP_ForceSword_C           = SWORD_GRIP,
	BP_ForceAxe_C             = SWORD_GRIP,
	BP_StormShieldLibrarian_C = SWORD_GRIP,
	BP_StormShield_C          = SWORD_GRIP,
	BP_PowerFist_C            = ARM_GRIP,
	BP_LightningClaw_C        = ARM_GRIP,
}

-- IGNITION (Force Sword) --------------------------------------------------

-- Raw LT, 0-255. Hysteresis so a trigger resting near the threshold does not
-- flutter the effect.
local LT_ON  = 40      -- ~15% pull ignites (same threshold Haptics uses)
local LT_OFF = 25

-- Seconds for a full ramp. Fade-out is longer so the blade gutters out
-- rather than snapping off.
local FADE_IN  = 0.12
local FADE_OUT = 0.35

-- Never ignite during menus or cutscenes (globals owned by MainHandler).
local RESPECT_MENUS = true

-- BLADE EFFECT (material slot 1, M_WeaponForceEffect_MAT) ------------------
-- An additive, unlit shell over the blade. Its "Color" parameter is the only
-- thing that makes it visible, so scaling it to 0 is a true "off".

local SHELL_FOLLOWS_LT = true

-- Stock colour is (0.2, 0.0566, 0.0044). BRIGHTNESS multiplies it: 1.0 is the
-- shipped look, 2-4 reads as a much hotter flame.
local FIRE_R, FIRE_G, FIRE_B = 0.2, 0.0566, 0.0044
local FIRE_BRIGHTNESS = 3.0

-- Panner speeds for the two texture layers. 1.0 = stock
-- (BorderFlow 0.005, DetailsFlow 0.1). Higher = faster-licking flame.
local FLOW_SCALE = 1.0

-- PARTICLES ---------------------------------------------------------------
-- PS_ForceSwordParticles_01_P: glowing motes drifting around the blade.
-- PS_WEAP_Lightning-02a: sprites + an anim trail at the "FX" socket. Left
-- alone by default in case its trail is the swing streak.
local MOTES_FOLLOW_LT     = true
local LIGHTNING_FOLLOWS_LT = false

-- LIGHT -------------------------------------------------------------------

local LIGHT_ENABLED = true

-- A point light stretched into a tube along the blade (SourceLength), so
-- highlights on walls and armour read as a line of fire, not a dot.
local LIGHT_INTENSITY   = 6000.0   -- inverse-squared units; a lamp is ~5000
local LIGHT_RADIUS      = 600.0    -- cm, hard cutoff. Cost scales ~radius^2
local LIGHT_R, LIGHT_G, LIGHT_B = 1.0, 0.45, 0.12
local LIGHT_TUBE        = 0.9      -- tube length as a fraction of the blade
local LIGHT_SOURCE_RADIUS = 4.0    -- cm, softness of the tube
local LIGHT_SHADOWS     = false    -- see NOTES before turning on

-- Fire flicker, as a fraction of intensity. 0 = steady.
local FLICKER_DEPTH = 0.35
local FLICKER_SPEED = 1.0

-- ARM GLOW (Power Fist, Lightning Claw) ------------------------------------
-- A light on the fist that ignites with LT like the sword's, but blue and
-- crackling. It hangs off L_PowerfistFX, a skeleton socket 50 cm down the
-- hand bone where the game spawns the fist's punch-impact FX: in front of
-- the palm while the hand is open, on the knuckles once it closes (and it
-- only lights while LT holds it closed). offset is cm in the socket's own
-- frame; +X is further out along the hand. Linear RGB.
local ARM_GLOW = {
	BP_PowerFist_C     = { socket = "L_PowerfistFX", offset = { 5.0, 0.0, 0.0 },
	                       r = 0.01, g = 0.10, b = 1.0 },
	BP_LightningClaw_C = { socket = "L_PowerfistFX", offset = { 5.0, 0.0, 0.0 },
	                       r = 0.01, g = 0.10, b = 1.0 },
}
local ARM_LIGHT_INTENSITY     = 6000.0
local ARM_LIGHT_RADIUS        = 600.0
local ARM_LIGHT_SOURCE_RADIUS = 10.0   -- cm: a ball of energy, not a pin-point
local ARM_FLICKER_DEPTH       = 0.45   -- electric: deeper and faster than fire
local ARM_FLICKER_SPEED       = 3.0

-- ARM BOOST ---------------------------------------------------------------
-- While LT is held, extra copies of the weapon's own electricity are laid
-- over it: denser arcs and, the emitters being additive, a brighter field.
-- Each copy is turned a different way so the arcs do not stack. They stop
-- emitting on release and let their arcs die out; nothing snaps off.
-- (PS_PowerFist_04_Nemesis, the game's own stronger variant, is red.)
local FXPS = "ParticleSystem /Game/RessourcesGFX/FX/Weapons/Terminator/MeleeWeapons/PS/"
local ARM_BOOST = {
	BP_PowerFist_C     = { template = FXPS .. "PS_PowerFist_04.PS_PowerFist_04", socket = "L_Hand" },
	BP_LightningClaw_C = { template = FXPS .. "PS_LightningClaw_03.PS_LightningClaw_03", socket = "L_Hand" },
}
local ARM_BOOST_COPIES = 2

-- ARM TRIM -----------------------------------------------------------------
-- Material slots on LArm to stop drawing, by index. The arm is rigidly bolted
-- to the controller with no IK, so a wrist roll swings the upper arm across
-- the view at unchanged distance -- which is why the materials' own
-- StartDistanceFade/RangeDistanceFade is the wrong tool here (measured
-- 2026-09-28: distance is not what distinguishes "in the way"). Removing the
-- geometry is immune to rotation.
--
-- Keyed by the mesh LArm currently shows, because arm weapons swap it (the
-- Power Fist is SK_TL-PowerFist-01a, whose slots are different parts).
--
-- SK_TL-LArm-01 slots, identified 2026-09-28 by exporting the mesh (umodel
-- -gltf) and rendering each section in its own colour:
--   0  M_TL-ArmsFoot-01a      elbow/upper-forearm armour, hollow at the top;
--                             reaches ~60 cm above the hand, so it swings
--                             widest when the wrist rolls. THE CLIPPING PART.
--   1  M_TL-LArm-01a          the engraved cuff just above the hand
--   2  M_TL-LHand-01a         the gauntlet
--   3  M_Terminator_Wire-01a  the hose; it runs up INTO slot 0, so it would
--                             dangle in mid-air without it
-- SK_TL-LArmFP-01a, the game's "first-person" arm, is NOT trimmed: same four
-- sections, same 10,090 vertices, same bounds -- only its materials differ.
--
-- SK_TL-RArm-01 (RArm, the gun arm) is the mirror image, slot for slot:
-- 0 the same ArmsFoot elbow armour (same 2254 vertices), 1 the
-- skull-engraved cuff, 2 the gauntlet, 3 the hose. Same trim.
-- UEVR's own saved "hide" on RArm (uobjecthook 3759916100792546786_props)
-- is re-applied every frame and beats this; untick it in UEVR to see RArm.
--
-- Delete an entry (or empty its list) to draw everything, as shipped.
-- holding = more slots hidden only while that arm's hand holds a stealer
-- (ZZGrab.isHolding): the cuff, so a held stealer's head does not cut
-- through the forearm -- only the gauntlet shows. (A layer within this
-- table: this file is at Lua's 200-local ceiling.)
local ARM_HIDE_SLOTS = {
	["SK_TL-LArm-01"] = { 0, 3, holding = { 1 } },
	["SK_TL-RArm-01"] = { 0, 3, holding = { 1 } },
}

-- Pawn components the trim looks at. Keys above are mesh names, so each
-- component is trimmed by whatever mesh it happens to be showing.
local TRIM_COMPONENTS = { "LArm", "RArm" }

-- FIRE ON KILL, RIGHT ARM POSE, RIG PROBE ----------------------------------
-- One table: this file shares Lua's 200-local ceiling.
local RX = {
	-- FIRE ON KILL. The Force Sword's DMGTypes ship as [4 Burn,
	-- 15 MeleeWeapon, 2 Psy] on EVERY hit, light or heavy, and whether a
	-- stealer burns is decided natively from that list -- no BP switch
	-- (AdjustedDamageType only ever ADDS 16 PowerHit, for a power attack).
	-- true = Burn only while LT is held, or for a heavy (LT) swing until its
	-- hit has landed. How the list is edited from Lua is in RX.rebuffer.
	BURN_GATE = true,
	BURN_CLASSES = { BP_ForceSword_C = true },
	-- After a heavy swing starts, Burn stays on this long even if LT is let
	-- go at once: the game charges for LI.HEAVY_HOLD, then the power attack
	-- plays and its hit lands partway through.
	BURN_AFTER_HEAVY = 1.6,     -- seconds
	BURN_DEBUG = false,         -- log every Burn on/off flip

	-- RIGHT ARM POSE. true = RArm stops copying the body animation (walk
	-- cycle, aim offset, recoil, reload) and holds one still frame, so the
	-- gun on its RGun socket stops bobbing. Keyed by the right weapon's
	-- class; anything not listed goes back to the body animation. The pose
	-- must be NON-ADDITIVE with the right hand CLOSED -- measured from the
	-- exported keys against the open A_T-Stormbolter-Idle01: the ForceSword
	-- attack sequences curl the right fingers 38 deg (the gun grip) and are
	-- additive-free. The obvious A_T-Stormbolter-Shoot-01b and -Reload are
	-- additive; Idle01/Pose02/Relax-01a/ParadeIdle-01 have the hand open.
	-- CameraManager's grip for a frozen arm is RARM_FROZEN_GRIP (re-tune).
	RIGHT_POSE = true,
	RIGHT_POSES = {
		-- Same frame as the left arm's SWORD_HOLD (defined further down).
		BP_StormBolter_C = { time = 0.0, anim = "AnimSequence /Game/RessourcesGFX/Characters/SpaceMarines/"
			.. "Terminators/Terminator01/Anims/Melee/ForceSword/A_T-ForceSword-Melee-L01.A_T-ForceSword-Melee-L01" },
	},

	-- RIG PROBE. Logs, once per swing of either hand, what the body did in
	-- the next PROBE_SECONDS: how far the pawn turned, how far the hips,
	-- chest and feet bones moved inside the hips mesh, and which of the
	-- anim BP's melee states came on. Diagnostic only; changes nothing.
	PROBE = true,
	PROBE_SECONDS = 1.5,
	PROBE_BONES = { "B_T_Hips", "B_T_Spine02", "B_T_ArmorBody", "B_T_L_Foot", "B_T_R_Foot" },
	PROBE_FLAGS = { "bMelee", "StateAMMelee", "HoldMeleePower", "EffectiveMelee", "MeleeHit", "bParadeHit" },
}

-- IMPALE (Force Sword) -----------------------------------------------------
-- A THRUST -- the blade driven point first, not swung -- through a
-- man-sized stealer kills it outright and leaves the body skewered: it
-- hangs off the blade where it was pierced and swings as you move, until a
-- sharp flick of the blade throws it off. While it is on the blade the
-- game's own sword attacks are held back, as they are while holding a
-- stealer; sheathing or changing weapon drops it. The kill (whole, as a
-- headshot: exactly lethal, explode off), the ragdoll carry and the fling
-- are ZZ_Grab's: the left hand's hold, with its point moved onto the blade.
RX.IMP = {
	ENABLED = true,
	CLASSES = { BP_ForceSword_C = true },
	-- A thrust: the hilt end of the blade moving point-first along the blade
	-- at THRUST_SPEED cm/s or more, within THRUST_ANGLE degrees of it. A slash
	-- moves it sideways; a wrist flick moves the tip, not the hilt. It must
	-- hold for two frames running. Speeds are the hand's own -- the pawn's
	-- velocity is taken out, so walking blade-first is not a thrust -- and a
	-- frame above JUMP_SPEED cm/s is a teleport or snap turn, not a motion.
	THRUST_SPEED = 180.0,
	THRUST_ANGLE = 35.0,
	JUMP_SPEED   = 1500.0,
	-- FORCE: only a hard thrust skewers. Its peak along-blade speed over the
	-- last FORCE_WINDOW s must reach FORCE_SPEED cm/s; a lighter thrust is
	-- just a thrust. Second session: impales came from 184-359 cm/s thrusts,
	-- most 190-270 -- nearly every push -- and only one would pass 320.
	-- REQUIRE_LT = true: also only with the blade lit (LT held).
	FORCE_SPEED  = 320.0,
	FORCE_WINDOW = 0.12,
	REQUIRE_LT   = false,
	-- The blade is searched from BLADE_FROM of the way from hilt to tip (the
	-- guard and the root of the blade do not skewer) to TIP_LEAD cm past the
	-- tip; a bone within REACH cm of that line is pierced. Bones run down the
	-- middle of the body, so REACH is "touching" plus body thickness.
	BLADE_FROM = 0.25,
	-- 2026-10-02, with the sword drawn at VIEW_SCALE: 10 cm past the tip and
	-- 30 cm of reach skewered stealers the blade had not reached yet ("impale
	-- the air in front"). Now the blade itself, and a bone within 24 cm of it
	-- (a genestealer's spine is ~15-20 cm inside its skin). Each impale logs
	-- the bone's distance and where along the blade it was, to tune from.
	TIP_LEAD   = 0.0,
	REACH      = 24.0,
	-- Where along the blade (0 hilt, 1 tip) the body is carried: where it was
	-- pierced, kept between these. Most first-session hits sat at the 0.9
	-- limit, i.e. hung off the tip of a 133 cm blade; 0.75 runs it on
	-- further.
	-- 0.75 held them a metre out, swinging under the tip (2026-10-03).
	HOLD_MIN = 0.25,
	HOLD_MAX = 0.5,
	-- Shaking it off: the pierce point moving at FLING_SPEED cm/s or more for
	-- two frames running. Anything gentler carries the body along. It only
	-- arms once the thrust itself is over: FLING_SETTLE s after the impale
	-- AND the point has slowed below FLING_REARM cm/s. Without that the
	-- thrust's own follow-through (the wrist turning, 570-905 cm/s at the
	-- pierce point, first session) threw every body straight back off.
	FLING_SPEED  = 700.0,
	FLING_SETTLE = 0.4,
	FLING_REARM  = 250.0,
	-- After a body comes off, no new impale for this long: a fling is often
	-- thrust-shaped itself.
	COOLDOWN = 0.6,
	-- { delay s, duration s, amplitude, frequency } -- a heavy double thunk.
	HAPTIC = { { 0.0, 0.10, 1.0, 1000.0 }, { 0.12, 0.10, 0.7, 1000.0 } },
	-- Played at the blade on the impale: { cue, volume, pitch }, each only if
	-- the level has it loaded. The fling uses the sword's own whoosh.
	SOUNDS = {
		{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Impacts/Mono/Gore/gore-dismemb-big.gore-dismemb-big", 1.0, 1.0 },
		{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Impacts/Mono/Foot/foot-hit-flesh.foot-hit-flesh", 0.8, 0.9 },
	},
	DEBUG = true,   -- log thrusts that found nothing, and the blade's peak speed while holding
}

-- WRIST (Force Sword) --------------------------------------------------------
-- The arm is one frozen frame bolted to the controller, so when your real
-- wrist turns down for a thrust the virtual forearm swings with the hand
-- instead of staying along your arm. Mod pak ~mods/950-ZZWristSweep_P.pak
-- (built by C:\temp\SpaceHulk-working\wristpose\bake.py) rewrites
-- A_T-ForceSword-Melee-L01 -- the sequence the hold already uses -- into a
-- wrist sweep: frame k turns the left forearm about the wrist by
-- ALPHA_MAX * k / (FRAMES - 1) degrees about AXIS_CS, the hand bone never
-- moving, so the tuned grip still holds the hilt. Frame 0 is the ordinary
-- hold, untouched (RArm and everything else use only that). The blade lies
-- along the forearm at 28.5 deg (frame 19): the thrust. Each tick your
-- real forearm is estimated -- shoulder from the eyes, then a two-bone arm
-- -- and the frame that lines the virtual forearm up with it is shown.
-- Without the pak this sequence is still the sword ATTACK, so a self-test
-- (hand bone fixed between first and last frame?) gates it.
RX.WRIST = {
	ENABLED   = true,
	CLASSES   = { BP_ForceSword_C = true },
	ALPHA_MAX = 60.0,
	FRAMES    = 41,
	LENGTH    = 1.3333334,
	FORE0_CS  = { 0.23032, 0.95369, -0.19349 },    -- elbow -> wrist at frame 0, LArm component space
	AXIS_CS   = { -0.32401, -0.11233, -0.93936 },  -- the sweep's turn axis, same space
	-- Your left shoulder from the eyes, cm, in the head's yaw frame
	-- (forward, right, up); arm lengths, cm. The elbow hangs down and out.
	SHOULDER  = { -8.0, -18.0, -25.0 },
	UPPER_ARM = 30.0,
	FOREARM   = 28.0,
	GAIN      = 1.0,    -- times the turn the estimate asks for
	SMOOTH    = 0.08,   -- s to ease most of the way to a new turn
	DEBUG     = true,   -- once a second while drawn: estimate, turn, off-axis part
	-- POINT DOWN: a second sweep in A_T-ForceSword-Melee-L02 (same pak,
	-- bake_down.py): frame 0 is the same hold, frame k turns the forearm
	-- about the wrist by DOWN_MAX * k / (FRAMES - 1) degrees about your
	-- controller's own pitch axis. Controller 45 deg down = about frame 26.
	-- One sweep shows at a time (asked 2026-10-01); changing from one to the
	-- other eases back through the hold first, so nothing jumps.
	DOWN_ANIM     = "AnimSequence /Game/RessourcesGFX/Characters/SpaceMarines/Terminators/Terminator01/Anims/"
	                .. "Melee/ForceSword/A_T-ForceSword-Melee-L02.A_T-ForceSword-Melee-L02",
	DOWN_MAX      = 70.0,
	PITCH_AXIS_CS = { 0.86071, -0.46373, 0.21006 },
	SWITCH_MARGIN = 6.0,   -- deg the other bend must lead by to take over
	NEUTRAL       = 2.0,   -- deg: the sweeps are swapped only this close to the hold
}

-- ARM IK + BODY ----------------------------------------------------------------
-- The controller-held arm (LArm / RArm) shows only the gauntlet. The rest
-- of the arm -- cuff, elbow and upper-arm armour, hose -- is a second copy
-- of that arm's mesh, the PIECE (a SkeletalMeshActor this file spawns),
-- placed every frame by a two-bone solve: its shoulder joint on the chest's
-- own shoulder joint, under the pauldron, its hand bone on the held arm's
-- hand bone, the elbow bent to fit and hanging down and out. The hand
-- follows the controller exactly; forearm and upper arm hang off the body.
-- LEFT: with the Force Sword equipped, drawn or sheathed (the bare hand).
-- RIGHT: whenever RArm is frozen on the
-- controller -- the storm bolter drawn (RX.RIGHT_POSE) or holstered, the
-- bare hand (RightHand.lua). Mod pak ~mods/951-ZZElbowBend_P.pak
-- (wristpose\bake_elbow.py) rewrites A_T-ForceSword-Melee-L03 into an
-- elbow sweep: frame k is the hold with BOTH elbows bent THETA_MAX * k / 40
-- deg from straight, the shoulders and upper arms fixed. A self-test per
-- arm (straight at frame 0, fully bent at the end) gates it; without the
-- pak the arms stay as they were. While the left piece shows, the wrist
-- sweeps are off.
--
-- BODY: the chest (Torso) is placed on a frame that follows the head's
-- position and the BODY's yaw (BodyYaw.lua's -- the hips'), not the head's
-- pitch and roll, so looking down no longer swings the chest or the
-- shoulder joints. PADS: the pauldrons rode the headset with no offset,
-- which -- their mesh being built around the feet like the chest's -- put
-- them ~1.9 m above your eyes; they now sit on the chest. Chest and
-- pauldrons copy the hips' animated pose (MasterPoseComponent), so on the
-- same transform they line up exactly. CameraManager stands down for what
-- this owns (ZZMelee_OwnsTorso, ZZMelee_OwnsShoulders).
RX.AIK = {
	ENABLED   = true,
	ANIM      = "AnimSequence /Game/RessourcesGFX/Characters/SpaceMarines/Terminators/Terminator01/Anims/"
	            .. "Melee/ForceSword/A_T-ForceSword-Melee-L03.A_T-ForceSword-Melee-L03",
	THETA_MAX = 150.0,      -- deg, the sweep's last frame (bake_elbow.py)
	PIECE_HIDE = { 2 },     -- slots hidden on a piece: the gauntlet (the held arm shows it)
	-- ...and also while that hand holds a LIVE stealer (RX.heldAlive; back
	-- the moment it dies): the cuff, as the held arm's trim does
	-- (ARM_HIDE_SLOTS holding), so the head does not cut it -- and since
	-- 2026-10-03 the elbow/upper-arm armour (0) and the hose (3) too, i.e.
	-- the whole piece: only the gauntlet shows during a grab.
	PIECE_HOLDING = { 0, 1, 3 },
	-- Per arm. The shoulder joint is the chest's B_T_L_Arm / B_T_R_Arm --
	-- the left measured 10 cm behind, 40 cm left of and 33 cm below the eyes
	-- (a man's is ~18 cm out); the chest copies the hips' animation, whose
	-- gun pose holds the right shoulder ~15 cm further forward -- plus
	-- SHOULDER_SHIFT, cm (forward, right, up), on the body frame. POLE: which
	-- way the elbow hangs, same frame: down, out and a little back.
	-- WRIST_LIMIT: this arm's hand is held to the wrist limits below (the
	-- gauntlet turned back past them). FOREARM_FOLLOW (0..1): the elbow goes
	-- round its circle to where the forearm lines up best with the hand's
	-- own forearm line, so the arm follows the hand -- the hand is never
	-- moved. BOTH ARMS ALIKE: never limited, always 1:1 on the controller --
	-- turn the hand across the body and the elbow swings out and up while
	-- forearm and upper arm come round after the hand. 2026-10-03: limiting
	-- the right bent the gun off the aim; limiting the left took the gauntlet
	-- and the sword off the left controller the same way, so the left now
	-- does exactly what the right does (POLE and the "out" side mirrored).
	L = {
		ENABLED = true,
		CLASSES = { BP_ForceSword_C = true },   -- the left weapon equipped (drawn or sheathed)
		ARM = "LArm",
		BONES = { "B_T_L_Arm", "B_T_L_Forearm", "B_T_L_Hand" },
		SHOULDER_SHIFT = { 0.0, 0.0, 0.0 },
		POLE = { -0.2, -0.5, -1.0 },
		WRIST_LIMIT = false,
		FOREARM_FOLLOW = 1.0,
	},
	R = {
		ENABLED = true,
		ARM = "RArm",
		BONES = { "B_T_R_Arm", "B_T_R_Forearm", "B_T_R_Hand" },
		SHOULDER_SHIFT = { 0.0, 0.0, 0.0 },
		POLE = { -0.2, 0.5, -1.0 },
		WRIST_LIMIT = false,
		FOREARM_FOLLOW = 1.0,
	},
	-- Shoulder to wrist the arm is 60.8 cm. Out of reach, the piece first
	-- grows up to STRETCH times; past that its shoulder end leaves the joint
	-- toward the hand (the hand never leaves the controller).
	STRETCH   = 1.10,
	-- ROLL: the arm turns with the hand, as a real one does at the shoulder.
	-- The elbow's side is taken from the held arm's own pose (its elbow
	-- hinge, which is rigid with the controller): thumb up, it hangs down,
	-- out and back -- both authored grips agree -- and turning the thumb out
	-- swings it out with the hand, so forearm and gauntlet never twist apart.
	-- 1 = all from the hand, 0 = POLE alone (the first version).
	ROLL_FOLLOW     = 1.0,
	-- The elbow may rise and swing out, but never point further IN (toward
	-- the body's middle) than straight down: past that it is held on the
	-- boundary, and the wrist share below may not take it there either.
	-- Degrees it may go in past straight down; 0 = not at all.
	ELBOW_IN_MAX    = 0.0,
	-- WRIST SHARE: past SHARE_FREE deg of bend at the wrist (the cuff covers
	-- the gauntlet up to about there), the forearm also turns WRIST_SHARE of
	-- the rest toward the line the held hand's own forearm takes, at most
	-- WRIST_SHARE_MAX deg, the elbow moving to suit, so a hard-bent wrist does
	-- not show the inside of the gauntlet. That authored line runs DOWN to
	-- the hand (the grip pose holds the elbow high), so sharing lifts the
	-- elbow: the dead zone keeps an ordinary hold where the arm puts it.
	-- Never past bending the elbow backwards, nor moving the arm's top more
	-- than SLIDE_OUT cm out from under the pauldron or SLIDE_IN cm into it.
	-- FOREARM_FOLLOW (per arm, above): the hand turned L deg across the body
	-- (in) swings the elbow FOLLOW_GAIN x L deg round the shoulder-hand line
	-- toward out; turned out, the same toward in -- even both ways -- at
	-- most FOLLOW_MAX either way. ELBOW_IN still stops it at straight down.
	FOLLOW_GAIN     = 0.5,
	FOLLOW_MAX      = 30.0,
	-- WRIST_SHARE 0 = the forearm ignores the wrist.
	-- 2026-10-03: 0. A real forearm does not turn when the wrist bends
	-- (thumb up, knuckles swung right: the forearm stays put); the user saw
	-- the forearm piece follow and asked for it not to. The wrist limits
	-- below keep the seam closed instead.
	WRIST_SHARE     = 0.0,
	SHARE_FREE      = 30.0,
	WRIST_SHARE_MAX = 30.0,
	SLIDE_OUT       = 3.0,
	SLIDE_IN        = 5.0,
	-- WRIST LIMITS: how far the gauntlet (the held arm) may bend against the
	-- forearm, deg, from where it sits straight in the cuff (its own pose's
	-- forearm line along the piece's forearm). Past a limit it is turned
	-- back about the wrist joint -- the hand stops as a wrist does, and the
	-- left weapon's mesh turns with it so the fist keeps the hilt (the
	-- bolter hangs off RArm and turns anyway). That moves the hand OFF the
	-- controller, so it is off on both arms (per arm, WRIST_LIMIT above);
	-- this switch and the numbers stay for an arm that turns it back on.
	-- Measured in the hand's own frame, so they mean the same at any arm
	-- pose. Arm out, thumb up:
	--   FLEX    knuckles swung left or right (toward the palm or the back of
	--           the hand), each way -- clipped, and no natural motion
	--   RADIAL  the hand tipped up and back, toward the thumb
	--   ULNAR   the hand tipped down, toward the little finger
	-- nil = no limit that way. 2026-10-03.
	WRIST_LIMIT  = true,
	WRIST_FLEX   = 20.0,
	WRIST_RADIAL = 15.0,
	WRIST_ULNAR  = 35.0,
	-- The headset this many cm further forward in the body than CameraManager
	-- had it: chest, pauldrons and shoulder joints all go back by it.
	HEAD_FORWARD    = 12.0,
	-- VIEW SCALE: the player's own armour and weapons as you see them --
	-- both arms (held and the IK pieces), the left weapon's mesh, the right
	-- weapon (it hangs off RArm's RGun socket, so it follows that arm), the
	-- chest and pauldrons -- drawn this size. Grips scale with it, so hands
	-- stay on the controllers; the chest shrinks toward the eyes. Hits,
	-- impales and bashes read the scaled sockets. The legs are not scaled.
	-- 1 = as the game draws them. CameraManager reads ZZMelee_ViewScale.
	VIEW_SCALE      = 0.90,
	PADS      = true,       -- the pauldrons onto the chest
	BODY      = true,       -- false: the chest stays on the headset, as CameraManager had it
	-- The chest relative to the head on the body frame: CameraManager's tuned
	-- headset attachment, measured live with the head level (2026-10-02),
	-- cm (forward, right, up) and deg (pitch, yaw, roll).
	TORSO_LOC = { 39.252, 20.191, -211.570 },
	TORSO_ROT = { 12.828, 7.341, -4.913 },
	DEBUG     = true,       -- once a second per arm while shown: reach, stretch, slide, elbow bend
}
ZZMelee_ViewScale = RX.AIK.VIEW_SCALE   -- CameraManager's RArm grip scales by it

-- REVERSE GRIP + POMMEL BASH (Force Sword) ------------------------------------
-- REVERSE: a quick brush of the LEFT thumbrest -- touched and let go within
-- BRUSH_MAX s -- turns the sword round in the fist: the blade comes out of
-- the little-finger side, the long hilt and pommel out of the thumb side.
-- Another brush turns it back. The thumbrest senses touch only, so a swipe
-- in any direction is a brush. Not when the right thumbrest went down
-- with it (both together is the Psygate, PsygateChord.lua). The grip is
-- SWORD_GRIP turned half a turn about FIST (the middle of the fist on the
-- hilt) round AXIS (hilt -> wrist), both in the sword mesh's own space,
-- worked out from whatever SWORD_GRIP holds, so a re-tuned grip carries
-- over (derived and checked against UEVR's placement maths 2026-10-02:
-- wristpose\reverse_grip.json). The fist does not move. The game's hit
-- sweep, the impale, the flame and its light all read the blade's sockets,
-- so they follow the turned blade.
RX.REV = {
	ENABLED   = true,
	CLASSES   = { BP_ForceSword_C = true },
	BRUSH_MAX = 0.35,     -- s, touch to release
	COOLDOWN  = 0.3,      -- s between turns
	CHORD     = 1.5,      -- s: a right thumbrest touch that began this close to the left's makes it the chord
	FIST      = { -3.657, 10.469, -4.131 },
	AXIS      = { 0.61048, -0.77333, 0.17112 },
	HAPTIC    = { 0.04, 0.6 },   -- s, amplitude (left hand)
}

-- BASH: the pommel end (POMMEL, sword mesh space; HILT is 18 cm back up the
-- hilt) driven at SPEED cm/s or more -- the pawn's own motion taken out --
-- into a man-sized stealer (a bone within REACH of the hilt's last stretch,
-- LEAD cm past the cap included) stuns it hard: the game's own shove
-- reaction (SHStealer.PushThisStealer; CHARGE = its charge version),
-- knocked back KNOCKBACK cm/s, and its AI held still for STUN_TIME s
-- (LockAIResources, the engine's own "pause this AI", as ZZ_Grab's holds
-- use). Always available, in either grip and whichever way the pommel
-- points; LEAD_ANGLE < 180 would require it to be moving pommel-first.
RX.BASH = {
	ENABLED    = true,
	CLASSES    = { BP_ForceSword_C = true },
	POMMEL     = { -0.566, 4.955, -40.079 },   -- the cap, 70 cm below the blade's base
	HILT       = { -2.090, 7.674, -22.351 },   -- 52 cm below it
	LEAD       = 6.0,
	SPEED      = 220.0,
	LEAD_ANGLE = 180.0,   -- off: any direction (first test: every fast pommel move found nothing at 22 cm)
	JUMP_SPEED = 1500.0,  -- a frame faster than this is a teleport or snap turn
	REACH      = 30.0,
	STUN_TIME  = 2.5,
	CHARGE     = true,
	KNOCKBACK  = 400.0,
	KNOCK_UP   = 120.0,
	COOLDOWN   = 0.5,
	HAPTIC     = { 0.12, 1.0 },
	-- { cue, volume, pitch }, each only if the level has it loaded.
	SOUNDS = {
		{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Impacts/Mono/Foot/foot-hit-flesh.foot-hit-flesh", 1.0, 0.8 },
		{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Impacts/Mono/armor/armor_hit_claw.armor_hit_claw", 0.6, 0.7 },
		{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Impacts/Flesh/terminator_rush.terminator_rush", 0.7, 1.0 },
	},
	DEBUG      = true,    -- log pommel-first moves that found nothing
}
-- SWORD HEFT -------------------------------------------------------------------
-- The blade has weight. Your hand (LArm) stays exactly on the controller, but
-- the sword's angle in the fist follows the controller through a spring,
-- turning about the fist (RX.REV.FIST), so the hilt stays in the hand: a hard
-- swing trails the tip, a sharp stop carries it a little past, and a slow
-- move or a still hand tracks exactly. WEIGHT_HZ: how fast it catches up
-- (lower = heavier; 6 trails ~6 deg at a 200 deg/s swing, ~23 at 800);
-- DAMPING: 1 = no swing past, lower = more; MAX_LAG: the most it ever trails
-- (deg); LIT: WEIGHT_HZ times this while the blade burns (< 1 = heavier).
-- The game's hits, the impale, the bash and the flame follow the blade you
-- see. UEVR's own attachment smoothing (UObjectHook_AttachLerpEnabled: ~67
-- ms of plain lag on every attached part, the left hand included) is
-- switched off while this is on, and put back if it is turned off.
RX.HEFT = {
	ENABLED   = true,
	CLASSES   = { BP_ForceSword_C = true },
	WEIGHT_HZ = 6.0,
	DAMPING   = 0.65,
	MAX_LAG   = 30.0,
	LIT       = 0.85,
	UEVR_LERP_OFF = true,
	DEBUG     = true,   -- every 2 s: the most the blade trailed
}

-- Hiding is done by swapping the slot for an ADDITIVE, unlit material with
-- its colour at zero: additive black contributes nothing, so the section
-- renders as truly invisible. 4.14 has no ShowMaterialSection, and
-- HideBoneByName is no use because hiding a bone hides its children too --
-- it would take the hand with it.
local INVISIBLE_MATERIAL =
	"Material /Game/RessourcesGFX/Weapons/ForceSword/Materials/M_WeaponForceEffect_MAT.M_WeaponForceEffect_MAT"

-- ARM POSE -----------------------------------------------------------------
-- true = LArm stops copying the body's animation (walk cycle, aim offset,
-- the flat game's melee poses) and holds a pose of its own: a still "open"
-- pose, swapped for "closed" while LT is held. Every pose here must be
-- NON-ADDITIVE (AdditiveAnimType 0) -- an additive sequence is a delta on a
-- base pose and deforms the arm if played alone. That rules out the
-- obvious-looking A_T-ForceSword-HandClose and A_T-Stormbolter-HandClose,
-- which are both additive; A_T-Stormbolter-Idle01 is the full non-additive
-- default-loadout idle, whose left hand already grips the sword.
local ARM_POSE_ENABLED = true
local ANIMS = "AnimSequence /Game/RessourcesGFX/Characters/SpaceMarines/Terminators/Terminator01/Anims/"
-- A_T-Stormbolter-Idle01 was tried first and leaves the hand OPEN: the base
-- idle poses the arm and the game curls the fingers with the additive
-- HandClose on top, which a single-node pose cannot layer. So the hold has
-- to come from a sequence whose own left hand already grips the hilt -- a
-- sword attack. openTime picks the frame; 0 is the wind-up, before the arm
-- swings out. All of these are non-additive, so any can be swapped in:
--   Melee/ForceSword/A_T-ForceSword-Melee-L01   41 fr, 1.33 s  (in use)
--   Melee/ForceSword/A_T-ForceSword-Melee-L02   41 fr, 1.33 s
--   Melee/A_T_ForceSword_PowerL-01a             31 fr, 1.00 s
--   A_T-Stormbolter-ParadeIdle-01               61 fr, 2.00 s  (guard stance)
local SWORD_HOLD = ANIMS .. "Melee/ForceSword/A_T-ForceSword-Melee-L01.A_T-ForceSword-Melee-L01"
local SWORD_HOLD_TIME = 0.0
local ARM_POSES = {
	BP_PowerFist_C = {
		open   = ANIMS .. "A_T_PowerFistLeftIdle-01a.A_T_PowerFistLeftIdle-01a",   -- 2 s idle
		closed = ANIMS .. "A_T_PowerFistLeftClose.A_T_PowerFistLeftClose",         -- 1 frame
	},
	BP_LightningClaw_C = {
		open   = ANIMS .. "A_T-LightningClaw-Idle01.A_T-LightningClaw-Idle01",
		closed = ANIMS .. "A_T-LightningClaw-HandClose-01a.A_T-LightningClaw-HandClose-01a",
	},
	-- The hand is already gripping, so LT changes nothing about the pose.
	BP_ForceSword_C           = { open = SWORD_HOLD, closed = SWORD_HOLD,
	                              openTime = SWORD_HOLD_TIME, closedTime = SWORD_HOLD_TIME },
	BP_ForceAxe_C             = { open = SWORD_HOLD, closed = SWORD_HOLD,
	                              openTime = SWORD_HOLD_TIME, closedTime = SWORD_HOLD_TIME },
	BP_StormShieldLibrarian_C = { open = SWORD_HOLD, closed = SWORD_HOLD,
	                              openTime = SWORD_HOLD_TIME, closedTime = SWORD_HOLD_TIME },
	BP_StormShield_C          = { open = SWORD_HOLD, closed = SWORD_HOLD,
	                              openTime = SWORD_HOLD_TIME, closedTime = SWORD_HOLD_TIME },
}
local ARM_OPEN_TIME = 0.0   -- seconds into the open animation to freeze at

-- true = the arm grip is corrected every frame so the hand bone (L_Hand)
-- stays where it sat when ARM_GRIP was tuned, whatever pose the arm is in.
-- HAND_REF is L_Hand in LArm's frame (X fwd, Y right, Z up) under the body's
-- idle pose, measured 2026-09-28 -- the pose ARM_GRIP was tuned in.
local HAND_LOCK = true
local HAND_REF  = { -13.6, -71.4, 142.2 }

-- LEFT INPUT ----------------------------------------------------------------
-- This file owns the left hand's buttons. Moved here from MainHandler
-- (2026-09-29), which stands its own copy down while ZZMelee_OwnsLeftInput
-- is set -- turn LI.ENABLED off to hand it all back unchanged.
--   swing          the game's melee attack (a synthetic LT), heavy if LT is
--                  held -- MainHandler's state machine, moved verbatim
--   LB             depends on the hand, decided on the press:
--     behind the head, holsterable weapon   sheathe / draw it
--     weapon drawn (or claw)                parry (LB to the game) + zoom
--     empty hand or Power Fist, on a stealer   grab it (ZZ_Grab)
--     empty hand, nothing there             reach for GRAB_WINDOW s, then
--                                           an open hand (a miss)
--     Power Fist, nothing there             parry
--   empty hand     a swing with an LT fist is a punch, never the game's attack
-- One table, not a run of locals: this file shares the 200-local ceiling.
local LI = {
	ENABLED = true,

	-- Swing, verbatim from MainHandler.
	MELEE_ON    = 43,     -- PosDiffSecondaryHand needed to start a swing
	MELEE_OFF   = 20,     -- must drop below this before another swing arms
	LIGHT_HOLD  = 0.12,   -- seconds: tap length, and the late-squeeze window
	HEAVY_HOLD  = 0.55,   -- seconds: charge length, must exceed game's threshold
	MELEE_CD    = 0.25,   -- seconds: lockout, guarantees a clean release edge
	MELEE_DEBUG = true,

	-- MainHandler also held the right mouse button (WeaponZoom in the game's
	-- input map; Parrying itself is gamepad LB) for as long as LB was down.
	-- Kept for the parry case so nothing changes there.
	LB_ZOOM = true,

	-- Mesh weapons that sheathe onto the back.
	HOLSTERABLE = {
		BP_ForceSword_C = true, BP_ForceAxe_C = true,
		BP_StormShield_C = true, BP_StormShieldLibrarian_C = true,
	},
	-- Sheathing and drawing make a sound at the hand (behind the head). The
	-- game has no sheath sound, so it is layered from what it does have
	-- loaded in a mission: a blade on metal (the "shing"), the sword whoosh,
	-- a mechanical click for the back mount's lock, and the power shield's
	-- activation for the weapon's power field coming up on the draw.
	-- { asset, volume, pitch } (a little random pitch on top); asset may be a
	-- list, the first one loaded is used; nothing loaded, skipped.
	-- 2026-10-01: the storm bolter reload clunk was tried for the lock and
	-- "sounds like a gun being cocked and loaded" -- no firearm sounds here.
	SHEATH_KIND = {
		BP_ForceSword_C = "blade", BP_ForceAxe_C = "blade",
		BP_StormShield_C = "shield", BP_StormShieldLibrarian_C = "shield",
	},
	SHEATH_SOUNDS = {
		blade = {
			sheathe = {
				{ { "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Impacts/Metal/imp_blade_metal_01_Cue.imp_blade_metal_01_Cue",
				    "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Impacts/Mono/ForceSword/imp-parry_sword.imp-parry_sword" }, 0.55, 0.85 },
				{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Whoosh/sword-Woosh.sword-Woosh", 0.7, 0.85 },
				{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Electronics/LightSwitch/light-switch-medium-cue.light-switch-medium-cue", 1.0, 0.7 },
			},
			draw = {
				{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Electronics/LightSwitch/light-switch-medium-cue.light-switch-medium-cue", 0.8, 0.8 },
				{ { "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Impacts/Metal/imp_blade_metal_01_Cue.imp_blade_metal_01_Cue",
				    "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Impacts/Mono/ForceSword/imp-parry_sword.imp-parry_sword" }, 0.6, 1.2 },
				{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Whoosh/sword-Woosh.sword-Woosh", 1.0, 1.0 },
				{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Skills/powershield_activate_Cue.powershield_activate_Cue", 0.8, 1.15 },
			},
		},
		shield = {
			sheathe = {
				{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Impacts/Mono/Shield/shield_hit.shield_hit", 0.5, 0.85 },
				{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Electronics/LightSwitch/light-switch-medium-cue.light-switch-medium-cue", 1.0, 0.7 },
			},
			draw = {
				{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Electronics/LightSwitch/light-switch-medium-cue.light-switch-medium-cue", 0.8, 0.8 },
				{ "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/Skills/powershield_activate_Cue.powershield_activate_Cue", 0.9, 1.0 },
			},
		},
	},
	-- The "behind the head" zone, metres, in the headset's frame (UEVR
	-- standing space: +x right, +y up, -z forward). HOLSTER_DEBUG logs the
	-- hand's position on every LB press, to tune these from.
	HOLSTER_MAX_DIST = 0.45,
	HOLSTER_BEHIND   = 0.0,     -- z at least this far behind the eyes
	HOLSTER_MIN_UP   = -0.20,   -- y no lower than this below the eyes
	HOLSTER_DEBUG    = true,
	-- A bump as the hand comes into that zone with a holsterable weapon
	-- (drawn or sheathed), so the spot can be found by feel. It has to
	-- leave by HOLSTER_ZONE_MARGIN m before it can bump again, so resting
	-- on the edge does not buzz.
	HOLSTER_ZONE_BUMP   = true,
	HOLSTER_ZONE_MARGIN = 0.05,
	HAPTIC_ZONE         = { 0.04, 0.7 },   -- seconds, amplitude

	-- Arm weapons that are a hand and can grab. Sheathed mesh weapons
	-- always can. The Lightning Claw is left out on purpose.
	GRAB_HANDS = { BP_PowerFist_C = true },

	-- A swing only punches with the fist closed -- and only LT closes a
	-- punching fist. LB is a grab, never a punch.
	PUNCH_NEEDS_FIST = true,

	-- LB on a bare hand is a GRAB, a reach that lasts GRAB_WINDOW s: the
	-- hand closes and keeps trying to take hold (the hand may still be on its
	-- way to the stealer). Nothing caught by then is a miss -- the hand opens
	-- again, LB still held or not, and does nothing more until LB is let go
	-- and pressed again.
	GRAB_WINDOW = 1.0,

	-- The bare hand of a sheathed weapon. While LB is held: the drawn
	-- weapon's own grip and pose, i.e. exactly the fist that holds the
	-- sword. Otherwise open (A_T-Stormbolter-Idle01: fingers open, because
	-- the game normally curls them with an additive layer), placed by
	-- LI.holdHand so the hand bone sits and points exactly as the fist's.
	-- History: a Power Fist grip + PowerFistLeftClose (hand moved, turned,
	-- knuckles missing); holdHand v1 (wrote scale, shrank the arm);
	-- BARE_OPEN_GRIP, the 2026-09-28 grip (right place, but pointed 90
	-- degrees up). BARE_OPEN_GRIP is used only with HOLD_HAND off.
	BARE_OPEN = ANIMS .. "A_T-Stormbolter-Idle01.A_T-Stormbolter-Idle01",
	BARE_OPEN_GRIP = { attach = "arm", loc = { -71.3, 139.1, 11.6 }, rot = { -50.0, 0.0, 55.0 } },
	HOLD_HAND = true,
	HAPTIC_SHEATHE = { 0.08, 0.9 },   -- seconds, amplitude
}

-- SOUND -------------------------------------------------------------------
-- A one-shot when the blade ignites and a loop while LT stays held, both
-- played from the blade and faded out on release. Only sounds the level has
-- already loaded can be used (4.14 has no Lua-callable synchronous load), so
-- each slot is a priority list: the first one found in memory wins, and a
-- slot with nothing loaded just stays silent.
--
-- Loaded in Chapter 02 (checked 2026-09-28). One-shots and their lengths:
--   pw-inferno-burst_Cue 5.1s   powershield_activate_Cue 2.0s
--   firestorm_Cue 5.0s          capacity-fire-cue 4.4s
--   sparks-burst-tiny 0.5s      wp_forceweapon_hit_Cue 1.4s
-- Loops: fire-big-loop-01_Cue, stealer_burn_loop_Cue,
--        pw-vortexofdoom-loop-01_Cue
local SOUND_ENABLED = true

local SND = "SoundCue /Game/SpaceHulk/Audio/SoundFXs/Dry/"
local IGNITE_SOUNDS = {
	SND .. "Powers/Inferno/pw-inferno-burst_Cue.pw-inferno-burst_Cue",
	SND .. "Skills/powershield_activate_Cue.powershield_activate_Cue",
	SND .. "Elements/Electricity/Sparks/sparks-burst-tiny.sparks-burst-tiny",
}
local LOOP_SOUNDS = {
	SND .. "Elements/Fire/fire-big-loop-01_Cue.fire-big-loop-01_Cue",
	SND .. "Creatures/Genestealer/stealer_burn_loop_Cue.stealer_burn_loop_Cue",
	SND .. "Powers/VortexOfDoom/pw-vortexofdoom-loop-01_Cue.pw-vortexofdoom-loop-01_Cue",
}

-- Multipliers on each cue's own volume/pitch. 0 volume disables that slot.
local IGNITE_VOLUME = 0.6
local IGNITE_PITCH  = 1.0
local LOOP_VOLUME   = 0.5
local LOOP_PITCH    = 1.0
local LOOP_FADE_IN  = 0.25   -- seconds
local SOUND_FADE_OUT = 0.4   -- seconds, both slots, on release

-- ARM SOUND (Power Fist, Lightning Claw) -----------------------------------
-- A spark snap on ignition, an electric loop while LT holds the fist
-- charged, and short spark crackles on top at random gaps and pitches, all
-- from the glow socket. Same priority-list rule as the sword's slots.
-- Loaded in Chapter 02 (checked 2026-09-28): stealer_elec_loop_Cue loops;
-- sparks-burst-tiny 0.5s, sparks-burst-medium-A 0.4s, light-sparks-medium
-- 0.4s; wp_laser-ion-charge 2.4s and powershield_activate 2.0s also fit.
local ARM_SOUND_ENABLED = true
local ARM_IGNITE_SOUNDS = {
	SND .. "Elements/Electricity/Sparks/sparks-burst-medium-A.sparks-burst-medium-A",
	SND .. "Electronics/LightSwitch/light-sparks-medium-cue.light-sparks-medium-cue",
}
local ARM_LOOP_SOUNDS = {
	SND .. "Creatures/Genestealer/stealer_elec_loop_Cue.stealer_elec_loop_Cue",
}
local ARM_CRACKLE_SOUNDS = {
	SND .. "Elements/Electricity/Sparks/sparks-burst-tiny.sparks-burst-tiny",
	SND .. "Elements/Electricity/Sparks/sparks-burst-medium-A.sparks-burst-medium-A",
}
local ARM_IGNITE_VOLUME  = 0.6
local ARM_LOOP_VOLUME    = 1.5          -- the cue itself ships at 0.4
local ARM_CRACKLE_VOLUME = 0.5
local ARM_CRACKLE_GAP    = { 0.15, 0.6 }  -- seconds between crackles, random
local ARM_CRACKLE_PITCH  = { 0.8, 1.4 }

-- CANNED SWING AND HIT FEEDBACK -------------------------------------------
-- true = the flat game's attack animation no longer moves the arms or the
-- body. The melee montages keep playing (so any timing the game reads from
-- them survives), but the anim BP's "MeleeSlot" node is renamed to None, so
-- their pose never reaches the skeleton the arm meshes copy. Hits are
-- unaffected -- the montages carry no notifies. Verified in-headset.
local MUTE_CANNED_SWING = true

-- false = no camera shake when a melee hit connects. This is the weapon's
-- own OnHitStealerPlayCamShake flag, which gates the whole of
-- BP_MeleeWeaponMother.CamShakeAndPowerfist; every other camera shake in the
-- game is left alone.
local MELEE_HIT_CAMSHAKE = false

-- SWING SOUND ---------------------------------------------------------------
-- true = the weapon's whoosh plays the moment your arm actually swings, from
-- the weapon itself, instead of whenever the flat game's attack gets to it.
-- The BP's own play is silenced by nulling the weapon instance's SwingSound;
-- the cue is taken from the class defaults, so each weapon keeps its own.
local SWING_SOUND_ON_MOTION = true
-- Left-hand speed, on MeleePower's scale (PosDiffSecondaryHand). ON matches
-- MainHandler's MELEE_ON, so the whoosh fires with the attack trigger.
local SWING_SPEED_ON   = 43
local SWING_SPEED_OFF  = 20    -- must drop below this before the next whoosh
local SWING_SPEED_FULL = 90    -- whoosh reaches full volume at this speed
local SWING_VOLUME     = 1.0

-- HIT DETECTION -----------------------------------------------------------
-- True = the game's own melee sweep runs from the VISIBLE weapon (its
-- SocketEndTraceLine socket on the controller-held mesh) instead of the
-- invisible animated hand. Mesh weapons only; see NOTES.
local TRACE_FROM_VISIBLE_BLADE = true

-- Seconds between re-assert passes for state the game's BP could reset.
local POLL_INTERVAL = 0.5

local LOG = true   -- logs on bind, on weapon change and on failures only

--==========================================================================
-- STATE
--   Prefixed globals, not locals -- this file shares the 200-local ceiling.
--==========================================================================

ZZM_level      = ZZM_level      or 0.0     -- 0 = cold, 1 = fully ignited
ZZM_lit        = ZZM_lit        or false   -- hysteresis latch on LT
ZZM_rawLT      = ZZM_rawLT      or 0
ZZM_time       = ZZM_time       or 0.0
ZZM_accum      = ZZM_accum      or 0.0
ZZM_sword      = nil
ZZM_mesh       = nil
ZZM_light      = nil     -- the PointLightComponent
ZZM_lightActor = nil     -- the APointLight that owns it
ZZM_lastColor  = -1.0
ZZM_lastVis    = nil
ZZM_wasLit     = false
ZZM_sndIgnite  = nil     -- the AudioComponents currently playing
ZZM_sndLoop    = nil
ZZM_cueIgnite  = nil     -- resolved SoundCues, re-looked-up on each bind
ZZM_cueLoop    = nil
ZZM_traceWeapon = nil    -- last weapon the trace fix was applied to
ZZM_armHooked  = false   -- this script attached LArm to the controller
ZZM_gripTarget = nil     -- address of the component last given a grip
ZZM_gripArmTarget = nil  -- same, for LArm when it rides alongside a mesh weapon
ZZM_trim = {}            -- [component name] = { comp, meshObj, orig = { [slot] = material before we hid it } }
ZZM_armHideWarned = false
ZZM_lastClass  = nil
ZZM_quatOK     = nil     -- nil untested, true/false once set_rotation_offset has answered
ZZM_armWeapon  = nil     -- arm weapon (fist, claw) whose glow is bound
ZZM_armLight   = nil
ZZM_armLightActor = nil
ZZM_handNow    = nil     -- L_Hand in LArm's frame this frame, for HAND_LOCK
ZZM_poseArm    = nil     -- LArm this script has taken off the body animation
ZZM_poseClass  = nil
ZZM_poses      = nil     -- resolved { open, closed } AnimSequences
ZZM_poseClosed = nil     -- pose last applied: true closed, false open
ZZM_armCues    = nil     -- resolved { ignite, loop, crackle } for the arm weapon
ZZM_crackleT   = 0.0     -- seconds until the next crackle
ZZM_swingCue   = nil     -- the current weapon's whoosh, from its class defaults
ZZM_swingArmed = true
ZZM_boostSpec  = nil     -- { template = ParticleSystem, socket } for the arm weapon
ZZM_boost      = nil     -- the spawned copies, while they are emitting
-- LEFT INPUT
ZZM_lbRaw      = false   -- LB as the controller reports it (xinput callback)
ZZM_lbWas      = false   -- LB last tick, for edges
ZZM_lbUse      = nil     -- what this press is: "holster" "parry" "grab" "reach" "miss" "done"
ZZM_lbPass     = false   -- let LB through to the game (parry)
ZZM_zoomDown   = false   -- the right-mouse zoom this file is holding
ZZM_mState     = "idle"  -- swing: idle / pressing / cooldown
ZZM_mT0        = 0.0
ZZM_mHeavy     = false
ZZM_mArmed     = true
ZZM_sheathed   = false   -- the mesh weapon is on the back, the hand is bare
ZZM_sheathWeapon = nil   -- the weapon that was sheathed
ZZM_ltFist     = false   -- LT latch: with the hand bare, LT closes the fist too
ZZM_grabUntil  = 0.0     -- ZZM_time until which an LB "reach" keeps trying to grab
-- Published for Haptics.lua (and used by applySwingSound): whether a fast
-- left hand is a weapon swing right now. See LI.leftSwings.
ZZMelee_LeftSwings = true

-- Tells CameraManager to leave LArm alone; this file owns the left hand.
ZZMelee_OwnsLeftHand = LEFT_HAND_ENABLED
-- Tells MainHandler to leave LT, the swing and LB alone; see LEFT INPUT.
ZZMelee_OwnsLeftInput = ENABLED and LI.ENABLED

--==========================================================================

local api = uevr.api

-- log_info, not print: print() never reaches log.txt in this profile.
local function log(fmt, ...)
	if LOG then
		local msg = "[Melee] " .. string.format(fmt, ...)
		pcall(function() uevr.params.functions.log_info(msg) end)
	end
end

local kmath = nil
local statics = nil
local pointLightActorClass = nil

local function resolveStatics()
	if kmath == nil then
		local c = api:find_uobject("Class /Script/Engine.KismetMathLibrary")
		kmath = c and c:get_class_default_object() or nil
	end
	if statics == nil then
		local c = api:find_uobject("Class /Script/Engine.GameplayStatics")
		statics = c and c:get_class_default_object() or nil
	end
	if pointLightActorClass == nil then
		pointLightActorClass = api:find_uobject("Class /Script/Engine.PointLight")
	end
	return kmath ~= nil and statics ~= nil and pointLightActorClass ~= nil
end

local function valid(obj)
	return obj ~= nil and UEVR_UObjectHook.exists(obj)
end

local function className(obj)
	local ok, n = pcall(function() return obj:get_class():get_fname():to_string() end)
	return ok and n or ""
end

-- Wrappers for the same UObject are not guaranteed to compare equal.
local function sameObject(a, b)
	if a == nil or b == nil then return a == b end
	return a:get_address() == b:get_address()
end

-- MainHandler publishes the raw LT in the LTrigger global before anything
-- touches it; ZZM_rawLT is the fallback for a profile without MainHandler.
--
-- This callback runs after MainHandler's (scripts load alphabetically) and
-- is the last word on what the game gets for the left hand, during gameplay
-- only -- menus and cutscenes get the controller untouched:
--   LT  never passes; it is 255 while a swing is "pressing", else 0
--   LB  passes only while the press has been judged a parry. The judging
--       happens in the tick, so a parry reaches the game one frame late.
local XINPUT_LB = 0x0100
uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
	if user_index ~= 0 then return end
	pcall(function()
		ZZM_rawLT = state.Gamepad.bLeftTrigger or 0
		ZZM_lbRaw = (state.Gamepad.wButtons & XINPUT_LB) ~= 0
		if not ZZMelee_OwnsLeftInput or isCinematic == true or isLTScreen == true then return end
		state.Gamepad.bLeftTrigger = (ZZM_mState == "pressing") and 255 or 0
		if ZZM_lbRaw and not ZZM_lbPass then
			state.Gamepad.wButtons = state.Gamepad.wButtons & ~XINPUT_LB
		end
	end)
end)

local function readLT()
	if type(LTrigger) == "number" then return LTrigger end
	return ZZM_rawLT
end

-- LeftWeaponActor, not LeftWeapon: LeftWeapon is an InterfaceProperty and
-- does not come through as a usable UObject in Lua.
local function resolveLeftWeapon()
	local pawn = api:get_local_pawn(0)
	if pawn == nil then return nil end
	local ok, lw = pcall(function() return pawn.LeftWeaponActor end)
	if not ok or lw == nil then return nil, pawn, "" end
	return lw, pawn, className(lw)
end

--==========================================================================
-- LEFT HAND -- written every tick, like CameraManager does for RArm, so a
-- re-equip or respawn picks the right grip up without a bind step.
--==========================================================================

-- Two-argument atan on any Lua: 5.1 has math.atan2, 5.3+ folds it into atan.
local function atan2(y, x)
	if math.atan2 ~= nil then return math.atan2(y, x) end
	return math.atan(y, x)
end

-- Fallback only. The Lua binding turns a Vector3d e into
-- glm::quat(glm::yawPitchRoll(-e.y, e.x, -e.z)) (lua-api ScriptContext.cpp),
-- so this is that function's inverse. An earlier version inverted
-- glm::quat(vec3) instead and put the sword 152 degrees off its grip.
local function quatToUevrEuler(w, x, y, z)
	local pitch = math.asin(math.max(-1.0, math.min(1.0, 2.0 * (w * x - y * z))))
	local yaw   = atan2(2.0 * (x * z + w * y), 1.0 - 2.0 * (x * x + y * y))
	local roll  = atan2(2.0 * (x * y + w * z), 1.0 - 2.0 * (x * x + z * z))
	return pitch, -yaw, -roll
end

local DEG2RAD = math.pi / 180.0

-- A quat entry goes in as a UEVR_Quaternionf, which set_rotation_offset
-- copies field by field -- exactly what UEVR saved, no conversion. The Euler
-- form is kept for a build that refuses the quaternion type.
local function setGripRotation(st, entry)
	if entry.quat ~= nil then
		local q = entry.quat
		if ZZM_quatOK ~= false then
			local ok, err = pcall(function()
				if entry._uq == nil then
					entry._uq = UEVR_Quaternionf.new()
					entry._uq.w, entry._uq.x, entry._uq.y, entry._uq.z = q[1], q[2], q[3], q[4]
				end
				st:set_rotation_offset(entry._uq)
			end)
			if ok then
				ZZM_quatOK = true
				return
			end
			ZZM_quatOK = false
			log("set_rotation_offset refused UEVR_Quaternionf (%s); using the Euler form", tostring(err))
		end
		if entry._euler == nil then
			entry._euler = { quatToUevrEuler(q[1], q[2], q[3], q[4]) }
		end
		local e = entry._euler
		st:set_rotation_offset(Vector3d.new(e[1], e[2], e[3]))
		return
	end
	local r = entry.rot or { 0.0, 0.0, 0.0 }
	local pitch = r[1]
	if entry.followViewPitch then pitch = pitch + (neededPitch or 0.0) end   -- owned by CameraManager
	st:set_rotation_offset(Vector3d.new(pitch * DEG2RAD, r[2] * DEG2RAD, r[3] * DEG2RAD))
end

-- FVector returns come back as a Vector3 whose fields may be lower- or
-- upper-case depending on the binding; accept either.
local function vecXYZ(v)
	local function f(lo, up)
		local ok, r = pcall(function() return v[lo] end)
		if ok and r ~= nil then return r end
		return v[up]
	end
	return f("x", "X"), f("y", "Y"), f("z", "Z")
end

-- L_Hand in LArm's own frame (X fwd, Y right, Z up). Socket and component
-- transforms are read in the same frame, so the result is the bone pose
-- alone, whatever UEVR has done to the component.
local function handInArm(arm)
	local ok, x, y, z = pcall(function()
		local w = arm:GetSocketLocation("L_Hand")
		return vecXYZ(kmath:InverseTransformLocation(arm:K2_GetComponentToWorld(), w))
	end)
	if ok and x ~= nil then return { x, y, z } end
	return nil
end

-- For an arm grip, hand is L_Hand this frame. The offset runs along LArm's
-- own axes as (left, down, forward) = (Y, Z, -X), so shifting it by
-- HAND_REF - hand keeps the hand bone exactly where the tuned grip put it,
-- whether the arm is in the body's walk cycle or one of our poses.
local function gripLocation(entry, hand)
	local l = entry.loc or { 0.0, 0.0, 0.0 }
	local s1, s2, s3 = l[1], l[2], l[3]
	if entry.followViewPitch then
		local p = (neededPitch or 0.0) / 45.0
		s2, s3 = s2 + p * 30.0, s3 + math.abs(p) * 30.0
	end
	if hand ~= nil then
		s1 = s1 - (HAND_REF[2] - hand[2])
		s2 = s2 - (HAND_REF[3] - hand[3])
		s3 = s3 + (HAND_REF[1] - hand[1])
	end
	-- The offset reaches a point of the part in its own (unscaled) frame, so
	-- a part drawn at RX.AIK.VIEW_SCALE needs it that much shorter.
	local k = RX.AIK.VIEW_SCALE
	return Vector3d.new(s1 * k, s2 * k, s3 * k)
end

local function releaseArm(arm)
	if ZZM_armHooked and arm ~= nil then
		pcall(function() UEVR_UObjectHook.remove_motion_controller_state(arm) end)
		log("left arm released from the controller")
	end
	ZZM_armHooked = false
	ZZM_gripArmTarget = nil   -- so TUNE mode writes again on the next attach
end

-- One grip write. hand is L_Hand this frame for an arm target, nil otherwise.
local function writeGrip(target, entry, hand)
	local st = UEVR_UObjectHook.get_or_add_motion_controller_state(target)
	if st == nil then return false end
	st:set_hand(0)
	setGripRotation(st, entry)
	st:set_location_offset(gripLocation(entry, hand))
	st:set_permanent(true)
	return true
end

local function applyLeftHand(pawn, lw, cls)
	if not LEFT_HAND_ENABLED or pawn == nil then return end
	local arm = nil
	pcall(function() arm = pawn.LArm end)

	-- Sheathed changes nothing here: the arm keeps the weapon's armGrip, and
	-- the hidden weapon keeps its attachment for when it is drawn.
	local entry = LEFT_WEAPONS[cls]
	if cls ~= ZZM_lastClass then
		ZZM_lastClass = cls
		if entry == nil then
			log("left weapon %s has no LEFT_WEAPONS entry; its attachment is left alone",
				cls ~= "" and cls or "(none)")
		else
			log("left weapon %s -> %s grip%s%s", cls, entry.attach,
				entry.armGrip ~= nil and " + arm" or "",
				TUNE_LEFT_HAND and " (TUNE: written once, then left to UEVR's UI)" or "")
		end
	end

	-- The arm rides the controller when it IS the weapon, or when a mesh
	-- weapon asks for it; otherwise it goes back to the body animation.
	local armEntry = nil
	if entry ~= nil then
		armEntry = (entry.attach == "arm") and entry or entry.armGrip
	end
	-- A sheathed weapon's bare hand, open: its own grip (see LI.BARE_OPEN_GRIP)
	-- -- unless LI.holdHand places it, which works from the weapon's grip.
	if armEntry ~= nil and not LI.HOLD_HAND and ZZM_sheathed and LI.HOLSTERABLE[cls]
		and not LI.handClosed(cls .. "#bare") then
		armEntry = LI.BARE_OPEN_GRIP
	end
	if armEntry == nil then releaseArm(arm) end
	if entry == nil or lw == nil then return end

	-- The weapon's own mesh, for a mesh weapon.
	if entry.attach ~= "arm" then
		local mesh = nil
		pcall(function() mesh = lw.MeleeWeapon end)
		if mesh ~= nil then
			local addr = mesh:get_address()
			if not (TUNE_LEFT_HAND and addr == ZZM_gripTarget) then
				ZZM_gripTarget = addr
				writeGrip(mesh, RX.revGrip(cls, entry), nil)   -- reversed while RX.revOn
			end
		end
	end

	-- LArm, either as the weapon itself or alongside a mesh weapon.
	ZZM_handNow = nil
	if armEntry == nil or arm == nil then return end
	local aAddr = arm:get_address()
	if TUNE_LEFT_HAND and aAddr == ZZM_gripArmTarget then return end
	ZZM_gripArmTarget = aAddr
	-- handLock = false means loc/rot are UEVR's own numbers, used verbatim.
	if HAND_LOCK and armEntry.handLock ~= false then ZZM_handNow = handInArm(arm) end
	if writeGrip(arm, armEntry, ZZM_handNow) then ZZM_armHooked = true end
end

--==========================================================================
-- HIT TRACE
--==========================================================================

-- Two parts, both needed:
--  1. SkeletalMeshValid: makes the BP trace from the weapon's end socket
--     instead of the actor root. Only claimed when true -- the socket branch
--     calls GetSocketTransform with no further guard.
--  2. Re-parent the mesh to the pawn's capsule. UEVR writes the hooked
--     mesh's RELATIVE transform, so while it hangs off the animated hand the
--     swing animation drags it ~2 m away from the controller during the
--     game tick -- exactly when the trace samples it -- and UEVR only puts it
--     back afterwards. The capsule moves only with locomotion.
-- Arm weapons have no MeleeWeapon mesh and fall out at the first check.
local function applyTraceSource(weapon, mesh, pawn)
	if not TRACE_FROM_VISIBLE_BLADE then return end
	local okM, skm = pcall(function() return mesh.SkeletalMesh end)
	if not okM or skm == nil then return end
	local okV, cur = pcall(function() return weapon.SkeletalMeshValid end)
	if okV and cur == false then
		weapon.SkeletalMeshValid = true
		log("melee trace on %s now reads its end socket", className(weapon))
	end

	if pawn == nil then return end
	local okR, root = pcall(function() return pawn:K2_GetRootComponent() end)
	if not okR or root == nil then return end
	local okP, parent = pcall(function() return mesh.AttachParent end)
	if okP and parent ~= nil and sameObject(parent, root) then return end
	-- KeepWorld: the mesh stays where UEVR last put it; UEVR's next write
	-- is then relative to the capsule.
	local okA, err = pcall(function() mesh:K2_AttachToComponent(root, "", 1, 1, 1, false) end)
	if okA then
		log("%s mesh re-parented from %s to the pawn capsule", className(weapon),
			parent ~= nil and parent:get_fname():to_string() or "nil")
	else
		log("re-parenting the weapon mesh failed: %s", tostring(err))
	end
end

--==========================================================================
-- CANNED SWING AND HIT FEEDBACK
--==========================================================================

-- ABP-Terminator-01's Slot node for "MeleeSlot", and where FAnimNode_Slot
-- keeps SlotName (measured: vtable, source pose link, then the FName).
local MELEE_SLOT_NODE  = "AnimGraphNode_Slot_C18EDE424DE01844C8B5D78FE055B1CB"
local SLOT_NAME_OFFSET = 0x48

local function slotNodeName(abp)
	local ok, n = pcall(function() return abp[MELEE_SLOT_NODE].SlotName:to_string() end)
	return ok and n or nil
end

-- Re-checked on every poll: the anim instance is rebuilt on respawn and
-- level load. Reflection confirms the name before and after the raw write,
-- so a different anim BP or layout is left untouched.
local function applyCannedSwing(pawn)
	if not MUTE_CANNED_SWING or pawn == nil then return end
	local abp = nil
	pcall(function() abp = pawn.Mesh.AnimScriptInstance end)
	if abp == nil or slotNodeName(abp) ~= "MeleeSlot" then return end
	local ok, err = pcall(function()
		local prop = abp:get_class():find_property(MELEE_SLOT_NODE)
		if prop == nil then error("slot node property not found") end
		local off = prop:get_offset() + SLOT_NAME_OFFSET
		local saved = abp:read_qword(off)
		abp:write_qword(off, 0)   -- FName None: index 0, number 0
		if slotNodeName(abp) ~= "None" then
			abp:write_qword(off, saved)
			error("SlotName did not read back as None; restored")
		end
	end)
	if ok then
		log("canned melee swing muted (MeleeSlot -> None)")
	else
		log("could not mute the canned swing: %s", tostring(err))
	end
end

-- Per weapon change and poll. The cue comes from the CDO so it survives the
-- instance having been nulled already (e.g. by an earlier load of this
-- script). BP_MeleeWeaponMother.PlaySound is Audio:SetSound(x) + Play, and
-- Play with no sound returns early, so a null SwingSound is a clean mute.
local function bindSwingSound(weapon)
	if not SWING_SOUND_ON_MOTION then return end
	local okC, cue = pcall(function()
		return weapon:get_class():get_class_default_object().SwingSound
	end)
	ZZM_swingCue = okC and cue or nil
	local okS, cur = pcall(function() return weapon.SwingSound end)
	if okS and cur ~= nil then
		local ok, err = pcall(function() weapon.SwingSound = nil end)
		if ok then
			log("swing sound on motion for %s: %s", className(weapon),
				ZZM_swingCue ~= nil and ZZM_swingCue:get_fname():to_string() or "none")
		else
			log("could not mute the BP's swing sound: %s", tostring(err))
		end
	end
end

local function applyHitShake(weapon)
	if MELEE_HIT_CAMSHAKE then return end
	local ok, v = pcall(function() return weapon.OnHitStealerPlayCamShake end)
	if ok and v == true then
		weapon.OnHitStealerPlayCamShake = false
		log("melee hit camera shake off on %s", className(weapon))
	end
end

--==========================================================================
-- FORCE SWORD -- bind
--==========================================================================

-- A light left behind by a previous load of this script is still attached
-- to the blade; adopt it instead of stacking a second one.
local function findExistingLight(mesh)
	local ok, kids = pcall(function() return mesh.AttachChildren end)
	if not ok or kids == nil then return nil end
	for _, c in ipairs(kids) do
		if c ~= nil and className(c) == "PointLightComponent" then
			return c
		end
	end
	return nil
end

-- Centre of the blade and a rotation whose X axis runs down it, which is the
-- axis SourceLength stretches along. Taken in world space from the sockets,
-- so it holds whatever the bone/socket layout is.
local function bladeTransform(mesh)
	local base = mesh:GetSocketLocation("BladeBase")
	local top  = mesh:GetSocketLocation("BladeTop")
	local dir  = kmath:Subtract_VectorVector(top, base)
	local mid  = kmath:Add_VectorVector(base, kmath:Multiply_VectorFloat(dir, 0.5))
	local rot  = kmath:Conv_VectorToRotator(dir)
	return kmath:MakeTransform(mid, rot, kmath:MakeVector(1.0, 1.0, 1.0)), kmath:VSize(dir)
end

-- add_component_by_class returns nil on this 4.14 build (no
-- AActor::AddComponentByClass yet), so the light is a whole APointLight actor
-- instead. Deferred spawn leaves a window before registration to make its
-- component Movable; the class default is Stationary, which expects baked
-- shadowmap channels a runtime light never gets.
local function spawnLight(sword, mesh)
	local xf, len = bladeTransform(mesh)
	local actor = statics:BeginDeferredActorSpawnFromClass(sword, pointLightActorClass, xf, 1, sword)
	if actor == nil then return nil, len end
	local comp = actor:K2_GetRootComponent()
	if comp ~= nil then comp.Mobility = 2 end
	statics:FinishSpawningActor(actor, xf)
	-- KeepWorld on all three: it was spawned exactly where it belongs.
	actor:K2_AttachToComponent(mesh, "", 1, 1, 1, false)
	return actor, len
end

local function configureLight(light, bladeLen)
	local steps = {
		function() light:SetCastShadows(LIGHT_SHADOWS) end,
		function() light:SetAttenuationRadius(LIGHT_RADIUS) end,
		function() light:SetLightColor(kmath:MakeColor(LIGHT_R, LIGHT_G, LIGHT_B, 1.0), true) end,
		function() light:SetSourceRadius(LIGHT_SOURCE_RADIUS) end,
		function() light:SetSourceLength(bladeLen * LIGHT_TUBE) end,
		function() light:SetIntensity(0.0) end,
		function() light:SetVisibility(false, false) end,
	}
	for i, fn in ipairs(steps) do
		local ok, err = pcall(fn)
		if not ok then log("light setup step %d failed: %s", i, tostring(err)) end
	end
end

local function bindLight(sword, mesh)
	local light = findExistingLight(mesh)
	local len = 130.0
	if light ~= nil then
		ZZM_lightActor = light:GetOwner()
		local okL, l = pcall(function() local _, n = bladeTransform(mesh) return n end)
		if okL and l ~= nil then len = l end
	else
		local ok, actor, l = pcall(spawnLight, sword, mesh)
		if not ok or actor == nil then
			log("could not spawn light: %s", tostring(actor))
			return nil
		end
		ZZM_lightActor = actor
		len = l or len
		light = actor:K2_GetRootComponent()
		if light == nil then
			log("light actor has no root component")
			return nil
		end
	end
	configureLight(light, len)
	log("light bound, blade %.0f cm, radius %.0f", len, LIGHT_RADIUS)
	return light
end

local function findCue(list)
	for _, path in ipairs(list) do
		local cue = api:find_uobject(path)
		if cue ~= nil then return cue end
	end
	return nil
end

local function cueName(cue)
	return cue ~= nil and cue:get_fname():to_string() or "none loaded"
end

-- Per bind, not per frame: what is loaded changes with the level, and
-- find_uobject is too slow to call every tick.
local function resolveCues()
	if not SOUND_ENABLED then return end
	ZZM_cueIgnite = findCue(IGNITE_SOUNDS)
	ZZM_cueLoop = findCue(LOOP_SOUNDS)
	log("sound: ignite=%s loop=%s", cueName(ZZM_cueIgnite), cueName(ZZM_cueLoop))
end

local function bindSword(sword, mesh)
	if mesh == nil then return false end
	ZZM_sword = sword
	ZZM_mesh = mesh
	ZZM_light = LIGHT_ENABLED and bindLight(sword, mesh) or nil
	resolveCues()
	ZZM_lastColor = -1.0
	ZZM_lastVis = nil
	log("bound to %s", sword:get_fname():to_string())
	return true
end

--==========================================================================
-- FORCE SWORD -- apply
--==========================================================================

-- The BP gives every slot a MID at spawn; NotifyNemesis swaps slot 1 for a
-- plain MIC, so a MID is made on demand rather than assumed.
local function shellMID(mesh)
	local mat = mesh:GetMaterial(1)
	if mat == nil then return nil end
	if className(mat) == "MaterialInstanceDynamic" then return mat end
	local ok, mid = pcall(function() return mesh:CreateDynamicMaterialInstance(1, mat) end)
	if ok and mid ~= nil then
		log("made a MID for the blade effect (was %s)", className(mat))
		return mid
	end
	return nil
end

local function applyShell(mesh, level, force)
	if not SHELL_FOLLOWS_LT then level = 1.0 end
	local k = level * FIRE_BRIGHTNESS
	if not force and math.abs(k - ZZM_lastColor) < 0.002 then return end
	local mid = shellMID(mesh)
	if mid == nil then return end
	mid:SetVectorParameterValue("Color", kmath:MakeColor(FIRE_R * k, FIRE_G * k, FIRE_B * k, 1.0))
	if force then
		mid:SetScalarParameterValue("BorderFlow", 0.005 * FLOW_SCALE)
		mid:SetScalarParameterValue("DetailsFlow", 0.1 * FLOW_SCALE)
	end
	ZZM_lastColor = k
end

local function setPSVisible(sword, prop, visible)
	local ok, ps = pcall(function() return sword[prop] end)
	if ok and ps ~= nil then
		pcall(function() ps:SetVisibility(visible, false) end)
	end
end

local function applyParticles(sword, visible, force)
	if not force and visible == ZZM_lastVis then return end
	setPSVisible(sword, "PS_ForceSwordParticles_01_P", visible or not MOTES_FOLLOW_LT)
	setPSVisible(sword, "ParticleSystem1", visible or not LIGHTNING_FOLLOWS_LT)
	ZZM_lastVis = visible
end

-- Three detuned sines: cheap, never repeats visibly, and reads as flame --
-- or, sped up and deepened, as a crackling power field.
local function flicker(t, speed, depth)
	t = t * speed
	local n = 0.5 * math.sin(t * 7.3) + 0.3 * math.sin(t * 13.1 + 1.7) + 0.2 * math.sin(t * 23.9 + 4.1)
	return 1.0 - depth * (0.5 + 0.5 * n)
end

local function applyLight(light, level, intensity, speed, depth)
	if not valid(light) then return end
	if level <= 0.001 then
		pcall(function() light:SetVisibility(false, false) end)
		return
	end
	pcall(function()
		light:SetVisibility(true, false)
		light:SetIntensity(intensity * level * flicker(ZZM_time, speed, depth))
	end)
end

-- The LT latch and ramp shared by every weapon that ignites: hysteresis on
-- the raw trigger, then a linear fade toward lit or cold.
local function updateIgnition(delta)
	local lt = readLT() or 0
	local blocked = RESPECT_MENUS and (isMenu == true or isCinematic == true)
	if blocked or lt < LT_OFF then
		ZZM_lit = false
	elseif lt >= LT_ON then
		ZZM_lit = true
	end
	if ZZM_lit then
		ZZM_level = math.min(1.0, ZZM_level + delta / math.max(FADE_IN, 0.001))
	else
		ZZM_level = math.max(0.0, ZZM_level - delta / math.max(FADE_OUT, 0.001))
	end
end

-- No component is added: SpawnSoundAttached builds its own AudioComponent
-- and hands it back, which is all FadeOut needs.
local function spawnSoundOn(attachTo, socket, cue, volume, pitch)
	if cue == nil or volume <= 0.0 or not valid(cue) or not valid(attachTo) then return nil end
	local ok, comp = pcall(function()
		-- 4.14 signature: Sound, AttachTo, Socket, Location, Rotation,
		-- LocationType (2 = SnapToTarget), bStopWhenAttachedToDestroyed,
		-- Volume, Pitch, StartTime, Attenuation, Concurrency.
		return statics:SpawnSoundAttached(cue, attachTo, socket,
			kmath:MakeVector(0.0, 0.0, 0.0), kmath:MakeRotator(0.0, 0.0, 0.0),
			2, true, volume, pitch, 0.0, nil, nil)
	end)
	if not ok then
		log("sound spawn failed: %s", tostring(comp))
		return nil
	end
	return comp
end

local function spawnOnBlade(cue, volume, pitch)
	return spawnSoundOn(ZZM_mesh, "BladeCenter", cue, volume, pitch)
end

local function fadeOutSound(comp)
	if valid(comp) then
		pcall(function() comp:FadeOut(SOUND_FADE_OUT, 0.0) end)
	end
end

local function silence()
	fadeOutSound(ZZM_sndIgnite)
	fadeOutSound(ZZM_sndLoop)
	ZZM_sndIgnite, ZZM_sndLoop = nil, nil
end

-- Edge-triggered on the same LT latch that drives the visuals, so sound and
-- flame always agree.
local function applySound()
	if not SOUND_ENABLED then return end
	if ZZM_lit and not ZZM_wasLit then
		silence()
		ZZM_sndIgnite = spawnOnBlade(ZZM_cueIgnite, IGNITE_VOLUME, IGNITE_PITCH)
		ZZM_sndLoop = spawnOnBlade(ZZM_cueLoop, LOOP_VOLUME, LOOP_PITCH)
		if valid(ZZM_sndLoop) and LOOP_FADE_IN > 0.0 then
			pcall(function() ZZM_sndLoop:FadeIn(LOOP_FADE_IN, 1.0, 0.0) end)
		end
	elseif not ZZM_lit and ZZM_wasLit then
		silence()
	end
	ZZM_wasLit = ZZM_lit
end

-- Hand the sword back as shipped: effect on, particles on, no light. Only a
-- MID this script may have darkened is touched; a MIC the BP swapped in
-- (Nemesis) already carries its own look.
local function releaseToStock()
	if valid(ZZM_mesh) then
		pcall(function()
			local mat = ZZM_mesh:GetMaterial(1)
			if mat ~= nil and className(mat) == "MaterialInstanceDynamic" then
				mat:SetVectorParameterValue("Color", kmath:MakeColor(FIRE_R, FIRE_G, FIRE_B, 1.0))
				mat:SetScalarParameterValue("BorderFlow", 0.005)
				mat:SetScalarParameterValue("DetailsFlow", 0.1)
			end
		end)
	end
	if valid(ZZM_sword) then applyParticles(ZZM_sword, true, true) end
	applyLight(ZZM_light, 0.0)
	silence()
	ZZM_lit, ZZM_wasLit = false, false
end

-- A light actor this file spawned and no longer needs. Never K2_DestroyActor
-- from here: called from this pre-engine-tick callback it hung the game
-- (2026-09-29, see LI.douse). Hidden now, and the engine destroys it itself
-- during its own tick when the life span runs out.
local function retireLight(actor)
	if not valid(actor) then return end
	pcall(function() actor:SetActorHiddenInGame(true) end)
	pcall(function() actor:SetLifeSpan(0.1) end)
end

-- The sword is no longer in hand (swapped, respawned, level change). The
-- light is a separate actor, so it is retired rather than left hanging
-- where the old blade was; the next bind spawns a fresh one.
local function releaseSword()
	if ZZM_sword == nil and ZZM_lightActor == nil then return end
	applyLight(ZZM_light, 0.0)
	silence()
	retireLight(ZZM_lightActor)
	ZZM_lit, ZZM_wasLit = false, false
	ZZM_sword, ZZM_mesh, ZZM_light, ZZM_lightActor = nil, nil, nil, nil
end

--==========================================================================

local function tickSword(sword, mesh, delta, force)
	if not sameObject(sword, ZZM_sword) or not valid(ZZM_mesh) then
		releaseSword()
		if not bindSword(sword, mesh) then return end
		force = true
	end

	-- Nemesis mode has its own look; stay out of its way until it ends.
	local okN, nemesis = pcall(function() return sword.NemesisIsActive end)
	if okN and nemesis == true then
		if ZZM_lastVis ~= "nemesis" then
			releaseToStock()
			ZZM_lastVis = "nemesis"
			ZZM_lastColor = -1.0
		end
		return
	end

	updateIgnition(delta)
	applyShell(ZZM_mesh, ZZM_level, force)
	applyParticles(sword, ZZM_level > 0.05, force)
	applyLight(ZZM_light, ZZM_level, LIGHT_INTENSITY, FLICKER_SPEED, FLICKER_DEPTH)
	applySound()
end

--==========================================================================
-- ARM GLOW (Power Fist, Lightning Claw)
--==========================================================================

-- The light rides LArm at a skeleton socket. LArm is the controller-held arm
-- mesh for these weapons, so the light follows the visible fist.
local function spawnSocketLight(owner, comp, socket)
	local xf = comp:GetSocketTransform(socket, 0)   -- RTS_World
	local actor = statics:BeginDeferredActorSpawnFromClass(owner, pointLightActorClass, xf, 1, owner)
	if actor == nil then return nil end
	local root = actor:K2_GetRootComponent()
	if root ~= nil then root.Mobility = 2 end
	statics:FinishSpawningActor(actor, xf)
	actor:K2_AttachToComponent(comp, socket, 2, 2, 2, false)   -- SnapToTarget
	return actor
end

local function randomIn(range)
	return range[1] + (range[2] - range[1]) * math.random()
end

-- Loop and snap edge-triggered on the shared LT latch, like the sword's;
-- crackles are fire-and-forget one-shots that finish on their own.
local function applyArmSound(arm, socket, delta)
	local c = ZZM_armCues
	if not ARM_SOUND_ENABLED or c == nil then return end
	if ZZM_lit and not ZZM_wasLit then
		silence()
		ZZM_sndIgnite = spawnSoundOn(arm, socket, c.ignite, ARM_IGNITE_VOLUME, 1.0)
		ZZM_sndLoop = spawnSoundOn(arm, socket, c.loop, ARM_LOOP_VOLUME, 1.0)
		if valid(ZZM_sndLoop) and LOOP_FADE_IN > 0.0 then
			pcall(function() ZZM_sndLoop:FadeIn(LOOP_FADE_IN, 1.0, 0.0) end)
		end
		ZZM_crackleT = randomIn(ARM_CRACKLE_GAP)
	elseif not ZZM_lit and ZZM_wasLit then
		silence()
	end
	ZZM_wasLit = ZZM_lit

	if ZZM_lit and c.crackle ~= nil then
		ZZM_crackleT = ZZM_crackleT - delta
		if ZZM_crackleT <= 0.0 then
			spawnSoundOn(arm, socket, c.crackle,
				ARM_CRACKLE_VOLUME * (0.6 + 0.4 * math.random()), randomIn(ARM_CRACKLE_PITCH))
			ZZM_crackleT = randomIn(ARM_CRACKLE_GAP)
		end
	end
end

-- SpawnEmitterAttached builds and registers its own ParticleSystemComponent
-- (4.14: Template, AttachTo, Socket, Location, Rotation, LocationType,
-- bAutoDestroy), so no AddComponentByClass is needed. KeepRelative (0) takes
-- Rotation as relative to the socket; bAutoDestroy cleans each copy up once
-- its last arc has died. ActorComponent.Deactivate, not DeactivateSystem:
-- the latter is not a UFunction on 4.14.
local function startBoost(arm)
	local spec = ZZM_boostSpec
	if spec == nil or ZZM_boost ~= nil then return end
	ZZM_boost = {}
	for i = 1, ARM_BOOST_COPIES do
		local ok, ps = pcall(function()
			-- MakeRotator(Roll, Pitch, Yaw): each copy spun about the hand.
			return statics:SpawnEmitterAttached(spec.template, arm, spec.socket,
				kmath:MakeVector(0.0, 0.0, 0.0), kmath:MakeRotator(i * 137.0, i * 61.0, 0.0),
				0, true)
		end)
		if ok and ps ~= nil then
			table.insert(ZZM_boost, ps)
		elseif not ok then
			log("boost emitter %d failed: %s", i, tostring(ps))
		end
	end
end

local function stopBoost()
	if ZZM_boost == nil then return end
	for _, ps in ipairs(ZZM_boost) do
		if valid(ps) then pcall(function() ps:Deactivate() end) end
	end
	ZZM_boost = nil
end

local function releaseArmGlow()
	if ZZM_armWeapon == nil and ZZM_armLightActor == nil then return end
	applyLight(ZZM_armLight, 0.0)
	silence()
	stopBoost()
	ZZM_lit, ZZM_wasLit = false, false
	retireLight(ZZM_armLightActor)
	ZZM_armWeapon, ZZM_armLight, ZZM_armLightActor, ZZM_armCues = nil, nil, nil, nil
	ZZM_boostSpec = nil
end

-- Bound once per weapon; a failed bind is not retried until the weapon
-- changes, so a missing socket cannot spam the log every frame.
local function bindArmGlow(weapon, arm, glow)
	ZZM_armWeapon = weapon
	local light = findExistingLight(arm)
	if light ~= nil then
		ZZM_armLightActor = light:GetOwner()
	else
		local ok, actor = pcall(spawnSocketLight, weapon, arm, glow.socket)
		if not ok or actor == nil then
			log("could not spawn the arm light: %s", tostring(actor))
			return
		end
		ZZM_armLightActor = actor
		light = actor:K2_GetRootComponent()
		if light == nil then return end
	end
	local steps = {
		function() light:SetCastShadows(false) end,
		function() light:SetAttenuationRadius(ARM_LIGHT_RADIUS) end,
		function() light:SetLightColor(kmath:MakeColor(glow.r, glow.g, glow.b, 1.0), true) end,
		function() light:SetSourceRadius(ARM_LIGHT_SOURCE_RADIUS) end,
		function() light:SetSourceLength(0.0) end,
		function() light:SetIntensity(0.0) end,
		function() light:SetVisibility(false, false) end,
		-- Relative to the socket, so it holds in any grip and any pose.
		function()
			local o = glow.offset or { 0.0, 0.0, 0.0 }
			local hit = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
			light:K2_SetRelativeLocation(kmath:MakeVector(o[1], o[2], o[3]), false, hit, false)
		end,
	}
	for i, fn in ipairs(steps) do
		local okS, err = pcall(fn)
		if not okS then log("arm light setup step %d failed: %s", i, tostring(err)) end
	end
	ZZM_armLight = light
	log("arm glow bound on %s at socket %s", className(weapon), glow.socket)

	if ARM_SOUND_ENABLED then
		ZZM_armCues = {
			ignite  = findCue(ARM_IGNITE_SOUNDS),
			loop    = findCue(ARM_LOOP_SOUNDS),
			crackle = findCue(ARM_CRACKLE_SOUNDS),
		}
		log("arm sound: ignite=%s loop=%s crackle=%s", cueName(ZZM_armCues.ignite),
			cueName(ZZM_armCues.loop), cueName(ZZM_armCues.crackle))
	end

	local boost = ARM_BOOST[className(weapon)]
	if boost ~= nil and ARM_BOOST_COPIES > 0 then
		local tpl = api:find_uobject(boost.template)
		ZZM_boostSpec = tpl ~= nil and { template = tpl, socket = boost.socket } or nil
		log("arm boost: %s x%d", tpl ~= nil and tpl:get_fname():to_string() or "not loaded",
			ARM_BOOST_COPIES)
	end
end

local function tickArmGlow(weapon, pawn, delta, glow)
	local arm = nil
	pcall(function() arm = pawn.LArm end)
	if arm == nil then return end
	if not sameObject(weapon, ZZM_armWeapon) then
		releaseArmGlow()
		bindArmGlow(weapon, arm, glow)
	end
	updateIgnition(delta)
	applyLight(ZZM_armLight, ZZM_level, ARM_LIGHT_INTENSITY, ARM_FLICKER_SPEED, ARM_FLICKER_DEPTH)
	applyArmSound(arm, glow.socket, delta)
	if ZZM_lit then startBoost(arm) else stopBoost() end
end

--==========================================================================
-- ARM POSE (Power Fist, Lightning Claw)
--==========================================================================

local function resolvePoses(spec)
	local open = api:find_uobject(spec.open)
	if open == nil then return nil end
	return {
		open       = open,
		closed     = api:find_uobject(spec.closed) or open,
		openTime   = spec.openTime or ARM_OPEN_TIME,
		closedTime = spec.closedTime or 0.0,
	}
end

-- Hand LArm back to the body: copy CharacterMesh0's pose again, as shipped.
-- The component outlives the weapon swap (only its mesh changes), so the
-- plain arm that comes back with the sword needs this too.
local function releaseArmPose(pawn)
	if ZZM_poseArm == nil then return end
	local arm = ZZM_poseArm
	ZZM_poseArm, ZZM_poseClass, ZZM_poses, ZZM_poseClosed = nil, nil, nil, nil
	if not valid(arm) then return end
	local ok, err = pcall(function()
		arm:SetAnimationMode(0)                  -- AnimationBlueprint
		arm:SetMasterPoseComponent(pawn.Mesh)
	end)
	if ok then
		log("left arm follows the body animation again")
	else
		log("restoring the left arm failed: %s", tostring(err))
	end
end

-- Off the master pose, LArm plays one frame of its own: the open idle
-- frozen at ARM_OPEN_TIME, or the closed fist while ZZM_lit (LT) holds.
local function applyArmPose(pawn, cls, poll)
	if not ARM_POSE_ENABLED then return end
	-- A sheathed weapon's bare hand: open idle, or the weapon's own grip
	-- pose while LB is held (see LI.BARE_OPEN and LI.holdHand).
	local key = cls
	local spec = ARM_POSES[cls]
	if ZZM_sheathed and LI.HOLSTERABLE[cls] and spec ~= nil then
		key = cls .. "#bare"
		spec = LI.bareSpec(spec)
	end
	local arm = nil
	pcall(function() arm = pawn.LArm end)
	if spec == nil or arm == nil then
		releaseArmPose(pawn)
		return
	end

	if ZZM_poseArm == nil or not sameObject(arm, ZZM_poseArm) or ZZM_poseClass ~= key then
		releaseArmPose(pawn)
		ZZM_poseArm, ZZM_poseClass, ZZM_poseClosed = arm, key, nil
		ZZM_poses = resolvePoses(spec)
		if ZZM_poses == nil then
			log("%s poses are not loaded; the arm keeps the body animation", key)
			return
		end
		log("left arm posed by this script for %s", key)
	end
	if ZZM_poses == nil then return end

	-- The game rebuilds LArm when it swaps the arm mesh on equip, so the
	-- mode is re-checked on every poll rather than trusted. It also links
	-- the arm back to the body mesh as its master pose, which makes it copy
	-- the body's animation (the walk cycle) while the mode still reads 1 --
	-- that is checked every tick (LI.masterLinked).
	local reset = LI.masterLinked(arm)
	if poll and not reset then
		local ok, mode = pcall(function() return arm:GetAnimationMode() end)
		reset = ok and mode ~= 1
	end
	local closed = LI.handClosed(key)
	if ZZM_poseClosed == closed and not reset then return end

	local ok, err = pcall(function()
		arm:SetMasterPoseComponent(nil)
		arm:SetAnimationMode(1)                  -- AnimationSingleNode
		arm:PlayAnimation(closed and ZZM_poses.closed or ZZM_poses.open, false)
		arm:SetPosition(closed and ZZM_poses.closedTime or ZZM_poses.openTime, false)
		-- The wrist sweep's current turn (and, pointing down, its sequence),
		-- so a re-pose never snaps it back.
		if RX.wristT ~= nil and RX.WRIST.CLASSES[key] then
			if RX.wristAsset ~= nil then arm:PlayAnimation(RX.wristAsset, false) end
			arm:SetPosition(RX.wristT, false)
		end
		arm:Stop()
	end)
	if ok then
		ZZM_poseClosed = closed
		-- For LI.holdHand: what is showing, since when, and which pose is the
		-- grip whose hand position is the reference.
		LI.poseAnim = closed and ZZM_poses.closed or ZZM_poses.open
		LI.poseAt   = LI.frame
		LI.gripAnim = ZZM_poses.closed
	else
		log("posing the left arm failed: %s", tostring(err))
		ZZM_poses = nil
	end
end

--==========================================================================
-- ARM TRIM
--==========================================================================

-- Our hiding material is recognised by what it is made from, not by
-- anything remembered: UEVR's script reload starts a fresh Lua state, so
-- remembered state would be lost and a trim could never be undone. Nothing
-- on either arm legitimately derives from the Force Sword's effect material.
local function isInvisible(mat, src)
	if mat == nil then return false end
	local ok, r = pcall(function() return sameObject(mat.Parent, src) end)
	return ok and r == true
end

-- The material a slot goes back to. The one that was there before is only
-- safe to hand back while it is still alive -- once swapped out it may be
-- referenced by nothing and collected, and a dead pointer would crash.
-- nil is always safe: the component falls back to its mesh's own material.
local function restoreTarget(orig)
	if orig ~= nil then
		local ok, alive = pcall(function() return UEVR_UObjectHook.exists(orig) end)
		if ok and alive then return orig end
	end
	return nil
end

-- One component. Every tick costs one pointer compare, so a mesh swap (arm
-- -> Power Fist) is caught at once; the slot scan runs then and on each
-- poll, which also re-hides a slot if the game ever puts its own material
-- back. st is this component's { comp, meshObj, orig } from last time.
local function trimComponent(comp, st, poll, holding)
	local meshObj = nil
	pcall(function() meshObj = comp.SkeletalMesh end)

	local changed = st == nil or not sameObject(comp, st.comp) or not sameObject(meshObj, st.meshObj)
	if not changed and not poll and st.holding == holding then return st end
	if changed then
		-- Originals captured on another mesh mean nothing on this one.
		st = { comp = comp, meshObj = meshObj, orig = {} }
	end
	st.holding = holding

	local src = api:find_uobject(INVISIBLE_MATERIAL)
	if src == nil then
		if not ZZM_armHideWarned then
			ZZM_armHideWarned = true
			log("arm trim: %s is not loaded; the arms are drawn whole", INVISIBLE_MATERIAL)
		end
		return st
	end

	local mesh = ""
	pcall(function() mesh = meshObj:get_fname():to_string() end)
	local want = {}
	local list = ARM_HIDE_SLOTS[mesh] or {}
	for _, s in ipairs(list) do want[s] = true end
	if holding then
		for _, s in ipairs(list.holding or {}) do want[s] = true end
	end

	local n = 0
	pcall(function() n = comp:GetNumMaterials() end)
	for slot = 0, n - 1 do
		local cur = nil
		pcall(function() cur = comp:GetMaterial(slot) end)
		local hidden = isInvisible(cur, src)
		if want[slot] and not hidden then
			local ok, err = pcall(function()
				local mid = comp:CreateDynamicMaterialInstance(slot, src)
				mid:SetVectorParameterValue("Color", kmath:MakeColor(0.0, 0.0, 0.0, 0.0))
			end)
			if ok then
				st.orig[slot] = cur
				log("arm trim: %s slot %d hidden", mesh, slot)
			else
				log("arm trim: hiding %s slot %d failed: %s", mesh, slot, tostring(err))
			end
		elseif hidden and not want[slot] then
			-- Off the list, or left over on a mesh the list does not cover.
			pcall(function() comp:SetMaterial(slot, restoreTarget(st.orig[slot])) end)
			st.orig[slot] = nil
			log("arm trim: %s slot %d drawn again", mesh, slot)
		end
	end
	return st
end

-- Whether that hand holds a live stealer (ZZGrab.isHoldingAlive), for the
-- held-arm trim and the arm piece's cuff; an older ZZ_Grab without it falls
-- back to holding anything.
function RX.heldAlive(hand)
	if ZZGrab == nil then return false end
	if ZZGrab.isHoldingAlive ~= nil then return ZZGrab.isHoldingAlive(hand) end
	return ZZGrab.isHolding(hand)
end

local function applyArmHide(pawn, poll)
	for _, name in ipairs(TRIM_COMPONENTS) do
		local comp = nil
		pcall(function() comp = pawn[name] end)
		if comp ~= nil then
			-- This arm's hand ("L" / "R") holding a LIVE one: its holding slots
			-- too -- back the moment it dies, body still in hand (2026-10-03).
			-- A body on the sword (impale) is held by the blade, not the hand.
			local h = name:sub(1, 1)
			local holding = ZZGrab ~= nil and RX.heldAlive(h)
				and not (h == "L" and ZZGrab.isImpaling ~= nil and ZZGrab.isImpaling()) or false
			-- That arm's piece draws the cuff (RX.AIK): the same slot.
			if RX.aikOn[h] then holding = true end
			ZZM_trim[name] = trimComponent(comp, ZZM_trim[name], poll, holding)
		end
	end
end

-- An RX feature that throws logs once and never takes the rest of the tick
-- down with it.
function RX.safe(name, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		RX.errs = RX.errs or {}
		if not RX.errs[name] then
			RX.errs[name] = true
			log("%s failed: %s", name, tostring(err))
		end
	end
end

--==========================================================================
-- FIRE ON KILL (Force Sword)
--==========================================================================
-- Lua cannot write an array's heap bytes: UObject write_* is bounds-checked
-- to the object itself, assigning an array property is "not supported
-- (yet)", and the generic Kismet array functions would take their element
-- size from an int32 wildcard. So the list is replaced, never edited:
--   1. once per sword, the ENGINE allocates a buffer holding [15, 2, 4]:
--      SetStringPropertyByName writes the string U+020F U+0004 into an
--      FString nothing reads (the material-editor comment CDO's Text), and
--      its UTF-16 is exactly the bytes 0F 02 04 00;
--   2. that FString's header and the sword's DMGTypes header are
--      exchanged, so each buffer still has exactly one owner and every later
--      free or realloc -- the sword's destruction, the donor's next
--      assignment -- lands on a genuine allocation;
--   3. from then on Burn is just DMGTypes.Num: 3 = [15, 2, 4], 2 = [15, 2].
-- The order differs from the shipped [4, 15, 2]; the set is the same.

RX.DMG_CLASS   = "Class /Script/SpaceHulkGame.SHMeleeWeapon"
RX.DONOR_CLASS = "Class /Script/Engine.MaterialExpressionComment"
RX.DONOR_OBJ   = "MaterialExpressionComment /Script/Engine.Default__MaterialExpressionComment"
RX.KSL         = "KismetSystemLibrary /Script/Engine.Default__KismetSystemLibrary"
RX.BURN_TEXT   = "\u{20F}\u{4}"

-- Offsets come from the class that declares the property.
function RX.offsetOf(classPath, prop)
	RX.offs = RX.offs or {}
	local key = classPath .. "." .. prop
	if RX.offs[key] == nil then
		local off = false
		pcall(function()
			local p = api:find_uobject(classPath):find_property(prop)
			if p ~= nil then off = p:get_offset() end
		end)
		RX.offs[key] = off
	end
	return RX.offs[key] or nil
end

-- A TArray header: data pointer, Num, Max.
function RX.readHdr(obj, off)
	return obj:read_qword(off), obj:read_dword(off + 8), obj:read_dword(off + 12)
end

function RX.writeHdr(obj, off, data, num, max)
	obj:write_qword(off, data)
	obj:write_dword(off + 8, num)
	obj:write_dword(off + 12, max)
end

-- The state for a sword whose DMGTypes is (now) our list, or nil + why.
function RX.rebuffer(sword)
	local off = RX.offsetOf(RX.DMG_CLASS, "DMGTypes")
	if not off then return nil, "DMGTypes offset not found" end
	local data, num, max = RX.readHdr(sword, off)
	-- Two entries is only ever ours: an earlier load of this script (a
	-- reload starts a fresh Lua state) left the rebuilt list in its no-Burn
	-- state. Adopt it as it is.
	if num == 2 and data ~= 0 then
		return { sword = sword, off = off, data = data, max = max }
	end
	if data == 0 or num ~= 3 then
		return nil, string.format("DMGTypes has %d entries, not the shipped 3", num)
	end

	local donor, ksl = api:find_uobject(RX.DONOR_OBJ), api:find_uobject(RX.KSL)
	local toff = RX.offsetOf(RX.DONOR_CLASS, "Text")
	if donor == nil or ksl == nil or not toff then return nil, "the donor string is not available" end

	ksl:SetStringPropertyByName(donor, "Text", RX.BURN_TEXT)
	local sData, sNum, sMax = RX.readHdr(donor, toff)
	-- Read back through the engine's own FString, i.e. the heap bytes
	-- themselves (the count includes the terminator).
	local back = donor.Text
	if sData == 0 or sNum ~= 3 or sMax < 3 or (back ~= RX.BURN_TEXT and back ~= RX.BURN_TEXT .. "\0") then
		return nil, string.format("the donor string came back wrong (num=%d max=%d)", sNum, sMax)
	end

	-- The exchange. Max is converted between bytes and UTF-16 units so
	-- neither side ever believes it has more room than was allocated.
	RX.writeHdr(sword, off, sData, 3, sMax * 2)
	RX.writeHdr(donor, toff, data, 0, max // 2)
	return { sword = sword, off = off, data = sData, max = sMax * 2 }
end

-- Every tick while the sword is drawn: Burn in the list only while LT is
-- held, for BURN_AFTER_HEAVY after a heavy swing starts, during the game's
-- own power attack, or in Nemesis (which has its own look anyway).
function RX.burnGate(sword, cls)
	if not RX.BURN_GATE or not RX.BURN_CLASSES[cls] then return end
	if not sameObject(RX.burnSword, sword) then
		RX.burnSword, RX.burn, RX.burnTries, RX.burnGaveUp = sword, nil, 0, false
	end
	if RX.burnGaveUp then return end

	local st = RX.burn
	if st ~= nil then
		local ok, d, n, m = pcall(RX.readHdr, sword, st.off)
		if not ok or d ~= st.data or m ~= st.max or (n ~= 2 and n ~= 3) then
			st, RX.burn = nil, nil
			log("fire gate: the game replaced the sword's DMGTypes; rebuilding")
		end
	end
	if st == nil then
		RX.burnTries = RX.burnTries + 1
		if RX.burnTries > 3 then
			RX.burnGaveUp = true
			log("fire gate: gave up on this sword; it burns as shipped")
			return
		end
		local ok, res, why = pcall(RX.rebuffer, sword)
		if not ok or res == nil then
			RX.burnGaveUp = true
			log("fire gate: left off for this sword (%s)", tostring(ok and why or res))
			return
		end
		st, RX.burn = res, res
		log("fire gate: DMGTypes is now [15 MeleeWeapon, 2 Psy, 4 Burn]; Burn follows LT")
	end

	if ZZM_mState == "pressing" and ZZM_mHeavy then RX.burnUntil = ZZM_time + RX.BURN_AFTER_HEAVY end
	local want = ZZM_lit or ZZM_time < (RX.burnUntil or -1.0)
	if not want then
		local okP, power = pcall(function() return sword:IsOwnerDoingAPowerAttack() end)
		want = okP and power == true
	end
	if not want then
		local okN, nem = pcall(function() return sword.NemesisIsActive end)
		want = okN and nem == true
	end
	local num = want and 3 or 2
	local _, n = RX.readHdr(sword, st.off)
	if n ~= num then
		sword:write_dword(st.off + 8, num)
		if RX.BURN_DEBUG then log("fire gate: Burn %s", want and "on" or "off") end
	end
end

--==========================================================================
-- RIGHT ARM POSE
--==========================================================================
-- Same mechanism as the left arm (ARM POSE). CameraManager reads
-- ZZMelee_RightArmFrozen: a frozen arm no longer tilts with aim pitch, so
-- its neededPitch staging would now tilt the gun off the controller, and it
-- uses the constant RARM_FROZEN_GRIP instead.

ZZMelee_RightArmFrozen = false

function RX.releaseRight(pawn, arm)
	RX.rArm, RX.rKey, RX.rAnim, RX.rPosed = nil, nil, nil, false
	ZZMelee_RightArmFrozen = false
	if not valid(arm) then return end
	local ok, err = pcall(function()
		arm:SetAnimationMode(0)                  -- AnimationBlueprint
		arm:SetMasterPoseComponent(pawn.Mesh)
	end)
	if ok then
		log("right arm follows the body animation again")
	else
		log("restoring the right arm failed: %s", tostring(err))
	end
end

function RX.rightPose(pawn, poll)
	local arm, cls = nil, ""
	pcall(function() arm = pawn.RArm end)
	pcall(function() cls = className(pawn.RightWeaponActor) end)
	if arm == nil then return end
	-- RightHand.lua poses the bare right hand while the gun is holstered at
	-- the hip. Stand aside (ZZMelee_RightArmFrozen keeps its value, so
	-- CameraManager's grip does not change under it) and pose the gun arm
	-- afresh once it has been drawn again.
	if ZZRight_OwnsArm then
		RX.rStoodDown = true
		return
	end
	if RX.rStoodDown then
		RX.rStoodDown, RX.rPosed = false, false
	end
	local spec = RX.RIGHT_POSE and RX.RIGHT_POSES[cls] or nil

	if spec == nil then
		-- Ours, or left frozen by an earlier load of this script: nothing
		-- else puts RArm in single-node mode.
		if RX.rArm ~= nil then
			RX.releaseRight(pawn, RX.rArm)
		elseif poll then
			local ok, mode = pcall(function() return arm:GetAnimationMode() end)
			if ok and mode == 1 then RX.releaseRight(pawn, arm) end
		end
		return
	end

	if RX.rArm == nil or not sameObject(arm, RX.rArm) or RX.rKey ~= cls then
		if RX.rFailed == cls then return end
		RX.rArm, RX.rKey, RX.rPosed = arm, cls, false
		RX.rAnim = api:find_uobject(spec.anim)
		if RX.rAnim == nil then
			RX.rFailed, RX.rArm = cls, nil
			log("right arm pose for %s is not loaded; the arm keeps the body animation", cls)
			return
		end
	end

	-- As with LArm, the mode is re-checked on every poll rather than trusted.
	local reset = not RX.rPosed
	if poll and not reset then
		local ok, mode = pcall(function() return arm:GetAnimationMode() end)
		reset = ok and mode ~= 1
	end
	if not reset then return end
	local ok, err = pcall(function()
		arm:SetMasterPoseComponent(nil)
		arm:SetAnimationMode(1)                  -- AnimationSingleNode
		arm:PlayAnimation(RX.rAnim, false)
		arm:SetPosition(spec.time or 0.0, false)
		arm:Stop()
	end)
	if ok then
		if not RX.rPosed then log("right arm posed by this script for %s", cls) end
		RX.rPosed = true
		ZZMelee_RightArmFrozen = true
	else
		RX.rFailed, RX.rArm = cls, nil
		log("posing the right arm failed: %s", tostring(err))
	end
end

--==========================================================================
-- RIG PROBE
--==========================================================================

function RX.yawOf(r)
	for _, k in ipairs({ "Yaw", "yaw", "y" }) do
		local ok, v = pcall(function() return r[k] end)
		if ok and type(v) == "number" then return v end
	end
	return nil
end

function RX.yawDiff(a, b)
	local d = (a - b) % 360.0
	if d > 180.0 then d = d - 360.0 end
	return math.abs(d)
end

-- Bone positions are in the hips mesh's own frame, so they show what the
-- animation does, apart from the capsule moving or turning.
function RX.sample(pawn)
	local s = { bones = {}, flags = {} }
	pcall(function() s.yaw = RX.yawOf(pawn:K2_GetActorRotation()) end)
	pcall(function() s.loc = { vecXYZ(pawn:K2_GetActorLocation()) } end)
	local mesh = nil
	pcall(function() mesh = pawn.Mesh end)
	if mesh == nil then return s end
	local okX, xf = pcall(function() return mesh:K2_GetComponentToWorld() end)
	if okX then
		for _, b in ipairs(RX.PROBE_BONES) do
			pcall(function()
				s.bones[b] = { vecXYZ(kmath:InverseTransformLocation(xf, mesh:GetSocketLocation(b))) }
			end)
		end
	end
	pcall(function() s.meshYaw = RX.yawOf(mesh.RelativeRotation) end)
	local abp = nil
	pcall(function() abp = mesh.AnimScriptInstance end)
	if abp ~= nil then
		for _, f in ipairs(RX.PROBE_FLAGS) do
			pcall(function() s.flags[f] = abp[f] end)
		end
	end
	return s
end

-- Starts on either hand crossing MainHandler's swing speed, samples every
-- tick for PROBE_SECONDS, then logs the largest change of each quantity.
function RX.probe(pawn, delta)
	if not RX.PROBE then return end
	local l, r = PosDiffSecondaryHand or 0, PosDiffWeaponHand or 0
	local p = RX.pr
	if p == nil then
		if l < LI.MELEE_OFF and r < LI.MELEE_OFF then RX.prArmed = true end
		if RX.prArmed and (l > LI.MELEE_ON or r > LI.MELEE_ON) then
			RX.prArmed = false
			RX.pr = { t = 0.0, hand = (l >= r) and "left" or "right", base = RX.sample(pawn),
				yaw = 0.0, yawAt = 0.0, mesh = 0.0, dist = 0.0, bone = {}, boneAt = {}, on = {} }
		end
		return
	end

	p.t = p.t + delta
	local s, b = RX.sample(pawn), p.base
	if s.yaw and b.yaw then
		local d = RX.yawDiff(s.yaw, b.yaw)
		if d > p.yaw then p.yaw, p.yawAt = d, p.t end
	end
	if s.meshYaw and b.meshYaw then p.mesh = math.max(p.mesh, RX.yawDiff(s.meshYaw, b.meshYaw)) end
	if s.loc and b.loc then
		p.dist = math.max(p.dist, math.sqrt((s.loc[1] - b.loc[1])^2 + (s.loc[2] - b.loc[2])^2))
	end
	for name, v in pairs(s.bones) do
		local v0 = b.bones[name]
		if v0 ~= nil then
			local d = math.sqrt((v[1] - v0[1])^2 + (v[2] - v0[2])^2 + (v[3] - v0[3])^2)
			if d > (p.bone[name] or 0.0) then p.bone[name], p.boneAt[name] = d, p.t end
		end
	end
	for f, v in pairs(s.flags) do
		if v == true then
			if p.on[f] == nil then p.on[f] = { p.t, p.t } else p.on[f][2] = p.t end
		end
	end
	if p.t < RX.PROBE_SECONDS then return end

	RX.pr = nil
	local parts, fl = {}, {}
	for _, name in ipairs(RX.PROBE_BONES) do
		if p.bone[name] then parts[#parts + 1] = string.format("%s %.1f cm @%.2fs", name, p.bone[name], p.boneAt[name]) end
	end
	for _, f in ipairs(RX.PROBE_FLAGS) do
		local o = p.on[f]
		if o then fl[#fl + 1] = string.format("%s %.2f-%.2fs", f, o[1], o[2]) end
	end
	local kind = p.hand == "right" and "no attack" or (ZZM_mHeavy and "heavy" or "light")
	log("rig probe (%s hand, %s): pawn turned %.1f deg @%.2fs, moved %.0f cm, mesh yaw %.1f deg | %s | on: %s",
		p.hand, kind, p.yaw, p.yawAt, p.dist, p.mesh, table.concat(parts, ", "),
		#fl > 0 and table.concat(fl, ", ") or "none")
end

--==========================================================================
-- IMPALE (Force Sword)
--==========================================================================
-- RX.imp: the body on the blade, or nil -- { point = fn, sword, u, t0,
-- last, prevS, peak, logT }. RX.impPrev: the blade last tick, for its
-- velocity. RX.impCool: no new impale before this ZZM_time.

-- The blade as hilt end (BladeBase) and tip (BladeTop), world cm.
function RX.impBlade(mesh)
	local ax, ay, az = vecXYZ(mesh:GetSocketLocation("BladeBase"))
	local bx, by, bz = vecXYZ(mesh:GetSocketLocation("BladeTop"))
	return ax, ay, az, bx, by, bz
end

function RX.impSounds(mesh)
	for _, e in ipairs(RX.IMP.SOUNDS) do
		local cue = LI.sound(e[1])
		if cue ~= nil then spawnSoundOn(mesh, "BladeCenter", cue, e[2], e[3]) end
	end
end

-- Let the body go: fling = true throws it with the blade's velocity.
function RX.impDrop(fling, why)
	local I = RX.imp
	RX.imp, RX.impPrev = nil, nil
	RX.impCool = ZZM_time + RX.IMP.COOLDOWN
	if I == nil then return end
	-- Flung: off the way the blade points now (hilt -> tip), not just the
	-- way the flick happened to move it.
	local aim = nil
	if fling and valid(I.mesh) then
		pcall(function()
			local ax, ay, az, bx, by, bz = RX.impBlade(I.mesh)
			aim = RX.vunit({ bx - ax, by - ay, bz - az })
		end)
	end
	if ZZGrab ~= nil and ZZGrab.isImpaling() then ZZGrab.release(fling, "L", aim) end
	if fling and ZZM_swingCue ~= nil and valid(I.mesh) then
		spawnSoundOn(I.mesh, "BladeCenter", ZZM_swingCue, SWING_VOLUME, 0.9 + 0.2 * math.random())
	end
	log("impale: %s (%s)", fling and "flung off" or "dropped", why)
end

-- Every tick. Holding: watch for the flick that throws it off. Not
-- holding: watch the blade for a thrust, and skewer what it meets.
function RX.impTick(pawn, lw, mesh, cls, delta)
	local C = RX.IMP
	local I = RX.imp
	local onBlade = ZZGrab ~= nil and ZZGrab.isImpaling ~= nil and ZZGrab.isImpaling()
	-- ZZ_Grab let go on its own (the body went, the pawn changed ...).
	if I ~= nil and not onBlade then
		RX.imp, RX.impCool = nil, ZZM_time + C.COOLDOWN
		log("impale: the hold ended")
		I = nil
	end
	local usable = C.ENABLED and ZZGrab ~= nil and ZZGrab.impale ~= nil and pawn ~= nil and lw ~= nil
		and mesh ~= nil and C.CLASSES[cls] == true and not ZZM_sheathed and LI.gameplay()
	if usable and I ~= nil and not sameObject(lw, I.sword) then usable = false end
	if not usable then
		if I ~= nil then RX.impDrop(false, "the sword is away") end
		RX.impPrev, RX.impThrust = nil, false
		return
	end
	if delta <= 0.0 then return end
	-- The pawn's own motion, taken out of every speed below.
	local pvx, pvy, pvz = 0.0, 0.0, 0.0
	pcall(function() pvx, pvy, pvz = vecXYZ(pawn:GetVelocity()) end)

	if I ~= nil then
		local okP, px, py, pz = pcall(I.point)
		if not okP or px == nil then
			RX.impDrop(false, "lost the blade")
			return
		end
		local q = I.last
		I.last = { px, py, pz }
		if q == nil then return end
		local s = math.sqrt(((px - q[1]) / delta - pvx) ^ 2 + ((py - q[2]) / delta - pvy) ^ 2
			+ ((pz - q[3]) / delta - pvz) ^ 2)
		if s > C.JUMP_SPEED then s = 0.0 end
		I.peak = math.max(I.peak or 0.0, s)
		if not I.armed then
			-- Still the thrust's own follow-through (see FLING_SETTLE).
			if ZZM_time - I.t0 >= C.FLING_SETTLE and s <= C.FLING_REARM then
				I.armed = true
				if C.DEBUG then log("impale: settled on the blade after %.2f s; a flick now throws it", ZZM_time - I.t0) end
			end
			I.prevS = 0.0
		else
			-- Two frames running, so one frame of tracking jitter cannot do it.
			if s >= C.FLING_SPEED and (I.prevS or 0.0) >= C.FLING_SPEED then
				RX.impDrop(true, string.format("the blade at %.0f cm/s", s))
				return
			end
			I.prevS = s
		end
		if C.DEBUG and ZZM_time - (I.logT or I.t0) >= 1.0 then
			I.logT = ZZM_time
			log("impale: holding; blade point peaked at %.0f cm/s this second (flings at %.0f)", I.peak, C.FLING_SPEED)
			I.peak = 0.0
		end
		return
	end

	local okB, ax, ay, az, bx, by, bz = pcall(RX.impBlade, mesh)
	if not okB then return end
	local prev = RX.impPrev
	RX.impPrev = { ax, ay, az }
	if prev == nil or ZZM_time < (RX.impCool or 0.0) or ZZGrab.isHolding("L") then
		RX.impThrust = false
		return
	end

	-- The hilt end's own velocity, split along the blade and across it.
	local lx, ly, lz = bx - ax, by - ay, bz - az
	local len = math.sqrt(lx * lx + ly * ly + lz * lz)
	if len < 1.0 then return end
	local dx, dy, dz = lx / len, ly / len, lz / len
	local vx = (ax - prev[1]) / delta - pvx
	local vy = (ay - prev[2]) / delta - pvy
	local vz = (az - prev[3]) / delta - pvz
	local along = vx * dx + vy * dy + vz * dz
	local cx, cy, cz = vx - along * dx, vy - along * dy, vz - along * dz
	local across = math.sqrt(cx * cx + cy * cy + cz * cz)
	local thrusting = along >= C.THRUST_SPEED and along <= C.JUMP_SPEED
		and across <= along * math.tan(math.rad(C.THRUST_ANGLE))
	local held = thrusting and RX.impThrust == true
	RX.impThrust = thrusting
	-- The thrust's force: its peak along-blade speed over FORCE_WINDOW.
	RX.impForce = RX.impForce or {}
	if thrusting then table.insert(RX.impForce, { ZZM_time, along }) end
	while #RX.impForce > 0 and ZZM_time - RX.impForce[1][1] > C.FORCE_WINDOW do table.remove(RX.impForce, 1) end
	if not held then return end
	local force = 0.0
	for _, e in ipairs(RX.impForce) do force = math.max(force, e[2]) end
	if force < C.FORCE_SPEED or (C.REQUIRE_LT and not ZZM_lit) then
		if C.DEBUG and ZZM_time - (RX.impLogT or -9.0) > 0.5 then
			RX.impLogT = ZZM_time
			log("impale: thrust at %.0f cm/s, too light to skewer (needs %.0f%s)", force, C.FORCE_SPEED,
				(C.REQUIRE_LT and not ZZM_lit) and ", and LT" or "")
		end
		return
	end

	-- A thrust. What is on the blade?
	local sx, sy, sz = ax + lx * C.BLADE_FROM, ay + ly * C.BLADE_FROM, az + lz * C.BLADE_FROM
	local ex, ey, ez = bx + dx * C.TIP_LEAD, by + dy * C.TIP_LEAD, bz + dz * C.TIP_LEAD
	local t = ZZGrab.findOnBlade(sx, sy, sz, ex, ey, ez, C.REACH)
	if t == nil then
		if C.DEBUG and ZZM_time - (RX.impLogT or -9.0) > 0.5 then
			RX.impLogT = ZZM_time
			log("impale: thrust at %.0f cm/s, nothing on the blade", along)
		end
		return
	end

	-- Carried where it was pierced, as a fraction of the blade from the hilt.
	local hx, hy, hz = sx + (ex - sx) * t.u, sy + (ey - sy) * t.u, sz + (ez - sz) * t.u
	local u = ((hx - ax) * dx + (hy - ay) * dy + (hz - az) * dz) / len
	u = math.max(C.HOLD_MIN, math.min(C.HOLD_MAX, u))
	local point = function()
		local a1, a2, a3, b1, b2, b3 = RX.impBlade(mesh)
		return a1 + (b1 - a1) * u, a2 + (b2 - a2) * u, a3 + (b3 - a3) * u
	end
	-- The blade's frame (base; axes X along it, Y the sword's right square to
	-- it, Z = X x Y): ZZ_Grab carries the trunk rigidly in it (skewered).
	local frame = function()
		local a1, a2, a3, b1, b2, b3 = RX.impBlade(mesh)
		local X = RX.vunit({ b1 - a1, b2 - a2, b3 - a3 })
		local yr = { vecXYZ(mesh:GetRightVector()) }
		local k = RX.vdot(yr, X)
		local Y = RX.vunit({ yr[1] - k * X[1], yr[2] - k * X[2], yr[3] - k * X[3] })
		return { a1, a2, a3 }, X, Y, RX.vcross(X, Y)
	end
	if ZZGrab.impale(pawn, cls, t, point, dx, dy, dz, C.HAPTIC, frame) then
		RX.imp = { point = point, mesh = mesh, sword = lw, u = u, t0 = ZZM_time }
		RX.impSounds(mesh)
		log("impale: thrust at %.0f cm/s (peak %.0f), %.0f deg off the blade; %s %.0f cm from the blade at %.2f of it; carried %.2f along",
			along, force, math.deg(math.atan(across / along)), tostring(t.bone and t.bone:to_string() or "?"), t.d or -1,
			C.BLADE_FROM + (1.0 - C.BLADE_FROM) * (t.u or 0.0), u)
	end
end

--==========================================================================
-- WRIST (Force Sword)
--==========================================================================
-- RX.eyes / RX.eyeYaw: UEVR's two views and the head's yaw, set in the view
-- callback below (a frame old by the next tick). RX.wristT: the sweep time
-- now shown (nil = not posing). RX.wristA: the eased turn, degrees.
-- RX.wristOk: nil untested, true the pak is loaded, false it is not.

RX.eyes = {}

-- The hand bone in LArm's own space.
function RX.handCS(arm)
	local loc, rot, scl = {}, {}, {}
	kmath:BreakTransform(arm:GetSocketTransform("L_Hand", 2), loc, rot, scl)   -- RTS_Component
	return { vecXYZ(loc.result) }
end

-- The two sweep sequences, looked up once: a find_uobject MISS scans every
-- object (~225 ms), so "not loaded" is cached as false.
function RX.wristAssets()
	if RX.holdObj == nil then RX.holdObj = api:find_uobject(SWORD_HOLD) or false end
	if RX.downObj == nil then RX.downObj = api:find_uobject(RX.WRIST.DOWN_ANIM) or false end
	return RX.holdObj or nil, RX.downObj or nil
end

local function wDist(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2) end

-- Once per arm: show the last frame of each sweep for a moment and check
-- the hand bone stayed put. Baked, it does to the millimetre; the stock
-- attacks move it a long way. Sets RX.wristOk (right sweep) and
-- RX.wristDownOk; returns true when decided, nil while testing.
function RX.wristTest(arm)
	local T = RX.wtest
	if T == nil or not sameObject(T.arm, arm) then
		RX.wtest = { arm = arm, step = 0 }
		return nil
	end
	local hold, down = RX.wristAssets()
	local L = RX.WRIST.LENGTH
	T.step = T.step + 1
	if T.step == 3 then
		T.h0 = RX.handCS(arm)
		arm:SetPosition(L, false)
	elseif T.step == 7 then
		T.h1 = RX.handCS(arm)
		if down ~= nil then
			arm:PlayAnimation(down, false); arm:SetPosition(L, false); arm:Stop()
		end
	elseif T.step == 11 then
		local h2 = down ~= nil and RX.handCS(arm) or nil
		if hold ~= nil then arm:PlayAnimation(hold, false) end
		arm:SetPosition(0.0, false); arm:Stop()
		local d1, d2 = wDist(T.h1, T.h0), h2 ~= nil and wDist(h2, T.h0) or -1.0
		RX.wristOk = d1 < 2.0
		RX.wristDownOk = RX.wristOk and h2 ~= nil and d2 < 2.0
		log("wrist: hand moved %.1f cm across the right sweep, %s across the down sweep -- right %s, down %s",
			d1, h2 ~= nil and string.format("%.1f cm", d2) or "(L02 not loaded)",
			RX.wristOk and "ON" or "OFF (pak not loaded?)", RX.wristDownOk and "ON" or "OFF")
		return true
	end
	return nil
end

-- Your real forearm, as a world direction (elbow -> wrist), from the hand
-- at (hx, hy, hz). Also returns shoulder-to-hand reach, cm.
function RX.wristEstimate(hx, hy, hz)
	local a, b = RX.eyes[0], RX.eyes[1]
	if a == nil or b == nil or RX.eyeYaw == nil then return nil end
	local C = RX.WRIST
	local yaw = math.rad(RX.eyeYaw)
	local fx, fy = math.cos(yaw), math.sin(yaw)        -- forward
	local rx, ry = -math.sin(yaw), math.cos(yaw)       -- right
	local s = C.SHOULDER
	local sx = (a[1] + b[1]) * 0.5 + fx * s[1] + rx * s[2]
	local sy = (a[2] + b[2]) * 0.5 + fy * s[1] + ry * s[2]
	local sz = (a[3] + b[3]) * 0.5 + s[3]
	local dx, dy, dz = hx - sx, hy - sy, hz - sz
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	if d < 1.0 then return nil end
	local ux, uy, uz = dx / d, dy / d, dz / d
	local U, F = C.UPPER_ARM, C.FOREARM
	if d >= U + F - 0.5 then return ux, uy, uz, d end   -- straight arm
	-- Elbow down and out (out = left, for the left arm), off the shoulder-hand line.
	local px, py, pz = -rx * 0.5, -ry * 0.5, -1.0
	local k = px * ux + py * uy + pz * uz
	px, py, pz = px - k * ux, py - k * uy, pz - k * uz
	local pl = math.sqrt(px * px + py * py + pz * pz)
	if pl < 1e-3 then return ux, uy, uz, d end
	px, py, pz = px / pl, py / pl, pz / pl
	local along = (U * U - F * F + d * d) / (2.0 * d)
	local h = math.sqrt(math.max(0.0, U * U - along * along))
	local ex, ey, ez = sx + ux * along + px * h, sy + uy * along + py * h, sz + uz * along + pz * h
	local vx, vy, vz = hx - ex, hy - ey, hz - ez
	local vl = math.sqrt(vx * vx + vy * vy + vz * vz)
	if vl < 1e-3 then return ux, uy, uz, d end
	return vx / vl, vy / vl, vz / vl, d
end

-- A world direction in LArm's own space.
function RX.wristLocal(arm, dx, dy, dz)
	local okD, v = pcall(function()
		return kmath:InverseTransformDirection(arm:K2_GetComponentToWorld(), kmath:MakeVector(dx, dy, dz))
	end)
	if not okD then return nil end
	return vecXYZ(v)
end

-- The turn (deg) about axis n that brings the virtual forearm (FORE0_CS) in
-- line with direction (x, y, z) -- both projected onto n's plane -- and how
-- far the direction lies off that plane (deg).
function RX.wristAngle(x, y, z, n)
	local u = RX.WRIST.FORE0_CS
	local k = x * n[1] + y * n[2] + z * n[3]
	x, y, z = x - k * n[1], y - k * n[2], z - k * n[3]
	local uk = u[1] * n[1] + u[2] * n[2] + u[3] * n[3]
	local ux, uy, uz = u[1] - uk * n[1], u[2] - uk * n[2], u[3] - uk * n[3]
	local cx, cy, cz = uy * z - uz * y, uz * x - ux * z, ux * y - uy * x
	local a = math.deg(math.atan(cx * n[1] + cy * n[2] + cz * n[3], ux * x + uy * y + uz * z))
	return a, math.deg(math.asin(math.max(-1.0, math.min(1.0, k))))
end

-- Put the drawn sword's arm back on the plain hold.
function RX.wristRelease(arm)
	local hold = RX.wristAssets()
	if RX.wMode == "down" and hold ~= nil then pcall(function() arm:PlayAnimation(hold, false) end) end
	pcall(function() arm:SetPosition(0.0, false); arm:Stop() end)
end

-- Every tick after the arm pose.
function RX.wristTick(pawn, cls, delta)
	local C = RX.WRIST
	local arm = ZZM_poseArm
	-- Not while the arm piece shows (RX.AIK): LArm is then only the gauntlet.
	local active = C.ENABLED and C.CLASSES[cls] == true and not ZZM_sheathed and arm ~= nil
		and valid(arm) and ZZM_poseClass == cls and LI.gameplay() and not RX.aikOn.L
	if not active then
		-- Still the drawn sword's pose (a menu, a cutscene): back to the hold.
		-- Not after a re-pose to something else (sheathed, a new weapon).
		if RX.wristT ~= nil and arm ~= nil and valid(arm) and ZZM_poseClass == cls then RX.wristRelease(arm) end
		RX.wristT, RX.wristA, RX.wMode, RX.wristAsset = nil, nil, nil, nil
		return
	end
	if RX.wristOk == nil or not sameObject(RX.wristArm, arm) then
		if RX.wristTest(arm) == nil then return end
		RX.wristArm = arm
	end
	if not RX.wristOk then return end

	local okH, hx, hy, hz = pcall(function() return vecXYZ(arm:GetSocketLocation("L_Hand")) end)
	if not okH then return end
	local fx, fy, fz, reach = RX.wristEstimate(hx, hy, hz)
	if fx == nil then return end
	local x, y, z = RX.wristLocal(arm, fx, fy, fz)
	if x == nil then return end
	local alpha, offR = RX.wristAngle(x, y, z, C.AXIS_CS)
	local beta, offD = RX.wristAngle(x, y, z, C.PITCH_AXIS_CS)
	local wantR = math.max(0.0, math.min(C.ALPHA_MAX, alpha * C.GAIN))
	local wantD = RX.wristDownOk and math.max(0.0, math.min(C.DOWN_MAX, beta * C.GAIN)) or 0.0

	-- One sweep at a time. The other takes over when it leads by
	-- SWITCH_MARGIN, but only once the shown one has eased back to the hold
	-- -- both sweeps' frame 0 IS the hold, so the swap there is invisible.
	local mode = RX.wMode or "right"
	local want = mode == "down" and wantD or wantR
	local other = mode == "down" and wantR or wantD
	if other > want + C.SWITCH_MARGIN then
		want = 0.0
		if (RX.wristA or 0.0) <= C.NEUTRAL then
			mode = mode == "down" and "right" or "down"
			local hold, down = RX.wristAssets()
			local seq = mode == "down" and down or hold
			if seq ~= nil then
				pcall(function() arm:PlayAnimation(seq, false); arm:SetPosition(0.0, false); arm:Stop() end)
			end
			RX.wristAsset = mode == "down" and down or nil
			RX.wristT = 0.0
			want = mode == "down" and wantD or wantR
		end
	end
	RX.wMode = mode

	local a = RX.wristA or 0.0
	a = a + (want - a) * math.min(1.0, delta / math.max(C.SMOOTH, 0.001))
	RX.wristA = a
	local t = a / (mode == "down" and C.DOWN_MAX or C.ALPHA_MAX) * C.LENGTH
	if RX.wristT == nil or math.abs(t - RX.wristT) > 0.002 then
		pcall(function() arm:SetPosition(t, false) end)
		RX.wristT = t
	end
	if C.DEBUG then
		RX.wLog = RX.wLog or { t = 0.0, r0 = 999.0, r1 = -999.0, d0 = 999.0, d1 = -999.0 }
		local L = RX.wLog
		L.r0, L.r1 = math.min(L.r0, alpha), math.max(L.r1, alpha)
		L.d0, L.d1 = math.min(L.d0, beta), math.max(L.d1, beta)
		if ZZM_time - L.t >= 1.0 then
			log("wrist: right asked %.0f..%.0f, down asked %.0f..%.0f deg this second; showing %s %.0f; reach %.0f cm",
				L.r0, L.r1, L.d0, L.d1, mode, a, reach)
			RX.wLog = { t = ZZM_time, r0 = 999.0, r1 = -999.0, d0 = 999.0, d1 = -999.0 }
		end
	end
end

--==========================================================================
-- ARM IK (Force Sword) + BODY
--==========================================================================
-- RX.body: { pawn, torso, torsoOwned } while chest and pauldrons are ours.
-- Per arm, keyed "L" / "R": RX.aik[side] the piece { side, actor, comp,
-- arm, len, theta, live, test, mat }; RX.aikOn[side] it shows this tick
-- (the held arm's cuff hidden; for L the wrist sweeps off); RX.aikCal[side]
-- the sweep in the piece's own space, from the self-test; RX.aikOk[side]
-- nil untested, true the pak is loaded, false it is not.
RX.aik, RX.aikOn, RX.aikCal, RX.aikOk, RX.aikFails = {}, {}, {}, {}, {}

function RX.wrap180(a)
	return (a + 180.0) % 360.0 - 180.0
end

function RX.vsub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
function RX.vdot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
function RX.vcross(a, b)
	return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
function RX.vunit(a)
	local l = math.sqrt(RX.vdot(a, a))
	if l < 1e-6 then return nil, 0.0 end
	return { a[1] / l, a[2] / l, a[3] / l }, l
end

-- A bone (or socket) in a component's own space.
function RX.boneCS(comp, name)
	local loc, rot, scl = {}, {}, {}
	kmath:BreakTransform(comp:GetSocketTransform(name, 2), loc, rot, scl)   -- RTS_Component
	return { vecXYZ(loc.result) }
end

-- The out-parameter K2_SetWorldLocationAndRotation insists on.
function RX.hit()
	if RX.hitObj == nil then
		RX.hitObj = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
	end
	return RX.hitObj
end

-- This view's body frame: the eyes' midpoint, and the body's yaw --
-- BodyYaw's (the hips'), brought up to this view's head yaw by BodyYaw's own
-- dead zone -- or, without BodyYaw, the head's. Returns origin, yaw (deg),
-- forward, right.
function RX.bodyFrame()
	local a, b = RX.eyes[0], RX.eyes[1]
	if a == nil or b == nil or RX.eyeYaw == nil then return nil end
	local yaw = RX.eyeYaw
	if ZZB ~= nil and ZZB_bodyYaw ~= nil then
		local dz = ZZB_deadzone or 0.0
		yaw = yaw - math.max(-dz, math.min(dz, RX.wrap180(yaw - ZZB_bodyYaw)))
	end
	local r = math.rad(yaw)
	-- BodyYaw's walk bob is the EYE moving against the BODY, so take it back
	-- out: this origin is the eye midpoint, and aikView sets the chest's world
	-- Z straight from it. Leave it in and the hood moves by exactly the bob,
	-- pinned to the eye -- net relative motion zero, which cancels the one
	-- thing the bob exists to produce and leaves the hood chasing the eye a
	-- frame late (that was the "something is still locking it in place"
	-- judder, 2026-10-02). Everything off this frame -- chest, pauldrons and
	-- the arm IK shoulders -- belongs on the body, so one subtraction here
	-- covers all three.
	local bob = ZZB_bob or 0.0
	return { (a[1] + b[1]) * 0.5, (a[2] + b[2]) * 0.5, (a[3] + b[3]) * 0.5 - bob }, yaw,
		{ math.cos(r), math.sin(r), 0.0 }, { -math.sin(r), math.cos(r), 0.0 }
end

-- A UEVR attachment off a component this file now places: CameraManager has
-- stood down, but its last one is still in UObjectHook.
function RX.unhook(comp, what)
	local ok, st = pcall(function() return UEVR_UObjectHook.get_motion_controller_state(comp) end)
	if ok and st ~= nil then
		pcall(function() UEVR_UObjectHook.remove_motion_controller_state(comp) end)
		log("body: %s is off the headset", what)
	end
end

-- A pauldron onto the chest: the chest's transform, and already the same
-- master pose (the hips), so the same bones land in the same places. One
-- bone is compared, which also catches the game moving either.
function RX.padOnChest(B, pad, torso)
	local name = pad:get_fname():to_string()
	RX.unhook(pad, name)
	local a = { vecXYZ(pad:GetSocketLocation("B_T_Spine02")) }
	local b = { vecXYZ(torso:GetSocketLocation("B_T_Spine02")) }
	if wDist(a, b) < 0.5 and sameObject(pad.AttachParent, torso) then return end
	pad:K2_AttachToComponent(torso, "None", 2, 2, 2, false)   -- SnapToTarget
	B.padFixes = (B.padFixes or 0) + 1
	if B.padFixes <= 4 then log("body: %s onto the chest (its bones were %.0f cm off)", name, wDist(a, b)) end
end

-- Every tick: take the chest and pauldrons (BODY / PADS), or hand them back.
function RX.bodyTick(pawn, poll)
	local C = RX.AIK
	local torso, lp, rp = nil, nil, nil
	pcall(function() torso, lp, rp = pawn.Torso, pawn.LShoulderPad, pawn.RShoulderPad end)
	local want = C.ENABLED and (C.BODY or C.PADS) and torso ~= nil
	local B = RX.body
	if B ~= nil and (not want or not sameObject(B.torso, torso)) then
		RX.bodyRelease()
		B = nil
	end
	if not want then return end
	if B == nil then
		B = { pawn = pawn, torso = torso }
		RX.body = B
		poll = true
		log("body: chest %s, pauldrons %s", C.BODY and "on the body frame" or "left on the headset",
			C.PADS and "on the chest" or "left on the headset")
	end
	ZZMelee_OwnsTorso = C.BODY
	ZZMelee_OwnsShoulders = C.PADS
	if not poll then return end
	if C.BODY then RX.unhook(torso, "the chest") end
	B.torsoOwned = C.BODY
	if C.PADS then
		if lp ~= nil then RX.padOnChest(B, lp, torso) end
		if rp ~= nil then RX.padOnChest(B, rp, torso) end
	end
end

-- Back to CameraManager, which hooks chest and pauldrons to the headset
-- again on its next tick (UObjectHook places them whatever they hang off).
function RX.bodyRelease()
	local B = RX.body
	RX.body = nil
	ZZMelee_OwnsTorso, ZZMelee_OwnsShoulders = false, false
	if B ~= nil then log("body: chest and pauldrons handed back to CameraManager") end
end

-- A script reload starts a fresh Lua state, so a piece spawned before it is
-- still on the arm: any SkeletalMeshActor's mesh under LArm / RArm is ours.
function RX.aikSweep(arm)
	pcall(function()
		for _, c in ipairs(arm.AttachChildren) do
			pcall(function()
				local owner = c:GetOwner()
				if owner ~= nil and className(owner) == "SkeletalMeshActor" then
					c:SetVisibility(false, true)
					owner:SetActorHiddenInGame(true)
					owner:SetLifeSpan(0.1)
					log("arm ik: retired an arm piece left over from before a script reload")
				end
			end)
		end
	end)
end

-- Hidden at once, destroyed by the engine on its own tick (never
-- K2_DestroyActor from here -- see retireLight).
function RX.aikRetire(side, why)
	local P = RX.aik[side]
	RX.aik[side], RX.aikOn[side] = nil, false
	if P == nil then return end
	if valid(P.actor) then
		pcall(function() P.comp:SetVisibility(false, true) end)
		pcall(function() P.actor:SetActorHiddenInGame(true) end)
		pcall(function() P.actor:SetLifeSpan(0.1) end)
	end
	log("arm ik %s: arm piece retired (%s)", side, why)
end

-- The piece's materials: the gauntlet hidden (the held arm draws it), the
-- cuff too while that hand holds a stealer, every other slot as the held
-- arm has it -- or had it before the trim hid it there (read once, at
-- spawn; false = the mesh's own).
function RX.aikMaterials(P, holding)
	local C = RX.AIK
	local src = api:find_uobject(INVISIBLE_MATERIAL)
	local hide = {}
	for _, s in ipairs(C.PIECE_HIDE) do hide[s] = true end
	if holding then
		for _, s in ipairs(C.PIECE_HOLDING) do hide[s] = true end
	end
	if P.mat == nil then
		P.mat = {}
		local st = ZZM_trim[C[P.side].ARM]
		local n = 0
		pcall(function() n = P.arm:GetNumMaterials() end)
		for slot = 0, n - 1 do
			local m = nil
			pcall(function() m = P.arm:GetMaterial(slot) end)
			if isInvisible(m, src) then
				m = st ~= nil and st.orig ~= nil and restoreTarget(st.orig[slot]) or nil
			end
			P.mat[slot] = m or false
		end
	end
	local n = 0
	pcall(function() n = P.comp:GetNumMaterials() end)
	for slot = 0, n - 1 do
		local cur = nil
		pcall(function() cur = P.comp:GetMaterial(slot) end)
		local hidden = isInvisible(cur, src)
		if hide[slot] then
			if src ~= nil and not hidden then
				pcall(function()
					local mid = P.comp:CreateDynamicMaterialInstance(slot, src)
					mid:SetVectorParameterValue("Color", kmath:MakeColor(0.0, 0.0, 0.0, 0.0))
				end)
			end
		elseif hidden or not P.matSet then
			local m = P.mat[slot]
			if m == false or (m ~= nil and not valid(m)) then m = nil end
			pcall(function() P.comp:SetMaterial(slot, m) end)
		end
	end
	P.matSet, P.holding = true, holding
end

-- A piece: a SkeletalMeshActor with the held arm's mesh, on the elbow
-- sweep, no collision, attached to the held arm so that between placements
-- it moves with the hand. Its bones refresh even while hidden, for the
-- self-test.
function RX.aikSpawn(side, pawn, arm)
	if RX.aikClass == nil then RX.aikClass = api:find_uobject("Class /Script/Engine.SkeletalMeshActor") or false end
	if RX.aikAnim == nil then RX.aikAnim = api:find_uobject(RX.AIK.ANIM) or false end
	if not RX.aikClass or not RX.aikAnim then
		log("arm ik: %s is not loaded; arm IK off", RX.aikAnim and "SkeletalMeshActor" or "A_T-ForceSword-Melee-L03")
		RX.aikOk.L, RX.aikOk.R = false, false
		return nil
	end
	RX.aikSweep(arm)
	local xf = arm:K2_GetComponentToWorld()
	local actor = statics:BeginDeferredActorSpawnFromClass(pawn, RX.aikClass, xf, 1, pawn)
	if actor == nil then
		RX.aikFails[side] = (RX.aikFails[side] or 0) + 1
		if RX.aikFails[side] >= 3 then
			RX.aikOk[side] = false
			log("arm ik %s: the arm piece would not spawn; off", side)
		end
		return nil
	end
	local root = actor:K2_GetRootComponent()
	if root ~= nil then root.Mobility = 2 end   -- Movable, before registration
	statics:FinishSpawningActor(actor, xf)
	local P = { side = side, actor = actor, arm = arm, len = 1.3333334, theta = 0.0 }
	RX.aik[side] = P   -- before anything can throw: never spawn twice
	local ok, err = pcall(function()
		local comp = actor.SkeletalMeshComponent or root   -- the root IS that component
		P.comp = comp
		comp:SetCollisionEnabled(0)
		comp.MeshComponentUpdateFlag = 0          -- AlwaysTickPoseAndRefreshBones
		comp:SetSkeletalMesh(arm.SkeletalMesh, true)
		comp:SetAnimationMode(1)                  -- AnimationSingleNode
		comp:PlayAnimation(RX.aikAnim, false)
		comp:SetPosition(0.0, false)
		comp:Stop()
		comp:SetCastShadow(arm.CastShadow == true)
		comp:SetBoundsScale(2.0)                  -- posed far from its reference pose
		comp:SetVisibility(false, true)
		comp:K2_AttachToComponent(arm, "None", 1, 1, 1, false)   -- KeepWorld
		local len = RX.aikAnim.SequenceLength
		if type(len) == "number" and len > 0.0 then P.len = len end
	end)
	if not ok then
		RX.aikOk[side] = false
		RX.aikRetire(side, "setting it up failed: " .. tostring(err))
		return nil
	end
	RX.aikMaterials(P, false)
	log("arm ik %s: arm piece spawned", side)
	return P
end

-- Once per arm: frame 0 must be the arm straight and the last frame bent
-- THETA_MAX, shoulder and elbow not moving -- the baked sweep, not the
-- stock attack. The same readings give the sweep's geometry in the piece's
-- own space. Returns true when decided (RX.aikOk[side] set), nil while
-- testing.
function RX.aikTest(P)
	local T = P.test
	if T == nil then
		T = { step = 0 }
		P.test = T
	end
	T.step = T.step + 1
	local comp, C, side = P.comp, RX.AIK, P.side
	local bn = C[side].BONES
	if T.step == 3 then
		T.a, T.e, T.w = RX.boneCS(comp, bn[1]), RX.boneCS(comp, bn[2]), RX.boneCS(comp, bn[3])
		comp:SetPosition(P.len, false)
	elseif T.step == 7 then
		local a, e, w = RX.boneCS(comp, bn[1]), RX.boneCS(comp, bn[2]), RX.boneCS(comp, bn[3])
		comp:SetPosition(0.0, false)
		P.theta = 0.0
		local u, lu = RX.vunit(RX.vsub(T.e, T.a))
		local f0, lf = RX.vunit(RX.vsub(T.w, T.e))
		local f1 = RX.vunit(RX.vsub(w, e))
		local b0, b1 = -1.0, -1.0
		if u ~= nil and f0 ~= nil and f1 ~= nil then
			b0 = math.deg(math.acos(math.max(-1.0, math.min(1.0, RX.vdot(u, f0)))))
			b1 = math.deg(math.acos(math.max(-1.0, math.min(1.0, RX.vdot(u, f1)))))
		end
		local drift = wDist(a, T.a) + wDist(e, T.e)
		local ok = b0 >= 0.0 and b0 < 3.0 and math.abs(b1 - C.THETA_MAX) < 3.0 and drift < 1.0
		RX.aikOk[side] = ok
		if ok then
			local h = RX.vunit(RX.vcross(u, f1))
			local cm = math.cos(math.rad(C.THETA_MAX))
			RX.aikCal[side] = { A = T.a, u = u, h = h, w = RX.vcross(u, h), lu = lu, lf = lf, len = P.len,
				dmin = math.sqrt(math.max(0.0, lu * lu + lf * lf + 2.0 * lu * lf * cm)) }
		end
		log("arm ik %s: elbow sweep bends %.1f -> %.1f deg (want 0 -> %.0f), shoulder/elbow drift %.2f cm, "
			.. "upper arm %.1f cm, forearm %.1f cm -- %s", side, b0, b1, C.THETA_MAX, drift, lu, lf,
			ok and "ON" or "OFF (951-ZZElbowBend_P.pak not loaded?)")
		return true
	end
	return nil
end

-- The held arm a piece should hang from this tick, or nil. LEFT: the Force
-- Sword equipped (CLASSES), drawn or sheathed, LArm posed by this file. RIGHT: RArm frozen on the
-- controller -- posed here for the drawn gun (RX.rightPose), or the bare
-- hand while the gun is holstered (RightHand.lua, ZZRight_OwnsArm).
function RX.aikWant(side, pawn, cls)
	local C, S = RX.AIK, RX.AIK[side]
	if not C.ENABLED or not S.ENABLED or RX.body == nil or RX.aikOk[side] == false or not LI.gameplay() then
		return nil
	end
	local arm = nil
	if side == "L" then
		-- Sheathed, LArm shows the bare hand: pose key "<cls>#bare" (applyArmPose).
		if S.CLASSES[cls] ~= true or (ZZM_poseClass ~= cls and ZZM_poseClass ~= cls .. "#bare") then return nil end
		arm = ZZM_poseArm
	else
		if ZZRight_OwnsArm ~= true and not RX.rPosed then return nil end
		pcall(function() arm = pawn[S.ARM] end)
	end
	if arm == nil or not valid(arm) then return nil end
	return arm
end

-- One arm, every tick: spawn, test, show or hide its piece.
function RX.aikSide(side, pawn, cls, poll)
	local arm = pawn ~= nil and RX.aikWant(side, pawn, cls) or nil
	local P = RX.aik[side]
	if P ~= nil and (not valid(P.comp) or not valid(P.arm) or (arm ~= nil and not sameObject(P.arm, arm))) then
		RX.aikRetire(side, "the arm changed")
		P = nil
	end
	if arm == nil then
		if P ~= nil and P.live then
			P.live = false
			pcall(function() P.comp:SetVisibility(false, true) end)
		end
		RX.aikOn[side] = false
		return
	end
	if P == nil then
		P = RX.aikSpawn(side, pawn, arm)
		if P == nil then
			RX.aikOn[side] = false
			return
		end
	end
	if RX.aikCal[side] == nil then
		if RX.aikTest(P) == nil then
			RX.aikOn[side] = false
			return
		end
		if not RX.aikOk[side] then
			RX.aikRetire(side, "no elbow sweep")
			return
		end
	end
	-- The same "holding" as the held arm's trim (applyArmHide): a live one.
	local holding = ZZGrab ~= nil and RX.heldAlive(side)
		and not (side == "L" and ZZGrab.isImpaling ~= nil and ZZGrab.isImpaling()) or false
	if poll or holding ~= P.holding then RX.aikMaterials(P, holding) end
	if not P.live then
		P.live = true
		P.comp:SetVisibility(true, true)
	end
	RX.aikOn[side] = true
end

-- Every tick after the arm poses.
function RX.aikTick(pawn, cls, poll)
	RX.safe("arm ik L", RX.aikSide, "L", pawn, cls, poll)   -- one arm's error never stops the other
	RX.safe("arm ik R", RX.aikSide, "R", pawn, cls, poll)
end

-- In the view callback, after UEVR, the hand hold and RightHand.lua's pin
-- have placed the held arms: the chest on the body frame, then the pieces
-- between chest and hands.
function RX.aikView()
	local B = RX.body
	if B == nil or not valid(B.torso) then return end
	if B.torsoOwned then
		local o, yaw, f, r = RX.bodyFrame()
		if o == nil then return end
		local l, q = RX.AIK.TORSO_LOC, RX.AIK.TORSO_ROT
		-- Drawn at VIEW_SCALE, shrunk toward the eyes; then HEAD_FORWARD back.
		local kv, hf = RX.AIK.VIEW_SCALE, RX.AIK.HEAD_FORWARD
		B.torso:K2_SetWorldLocationAndRotation(
			kmath:MakeVector(o[1] + f[1] * (kv * l[1] - hf) + r[1] * kv * l[2],
				o[2] + f[2] * (kv * l[1] - hf) + r[2] * kv * l[2], o[3] + kv * l[3]),
			kmath:MakeRotator(q[3], q[1], yaw + q[2]), false, RX.hit(), true)   -- roll, pitch, yaw
		if B.scale ~= kv then
			B.torso:SetWorldScale3D(kmath:MakeVector(kv, kv, kv))   -- the pauldrons on it follow
			B.scale = kv
		end
	end
	RX.safe("arm ik L (view)", RX.aikSolve, B, "L")
	RX.safe("arm ik R (view)", RX.aikSolve, B, "R")
end

-- v rotated by ang (radians) about unit axis a.
function RX.rotv(v, a, ang)
	local c, s = math.cos(ang), math.sin(ang)
	local k, x = RX.vdot(a, v), RX.vcross(a, v)
	return { v[1] * c + x[1] * s + a[1] * k * (1.0 - c), v[2] * c + x[2] * s + a[2] * k * (1.0 - c),
	         v[3] * c + x[3] * s + a[3] * k * (1.0 - c) }
end

-- A component turned by ang (radians) about unit axis ax through point W,
-- in the world. Its own rotation axes (not scaled), so a scaled arm keeps
-- its scale.
function RX.turnAbout(comp, W, ax, ang)
	local rot = comp:K2_GetComponentRotation()
	local X = RX.rotv({ vecXYZ(kmath:GetForwardVector(rot)) }, ax, ang)
	local Y = RX.rotv({ vecXYZ(kmath:GetRightVector(rot)) }, ax, ang)
	local Z = RX.rotv({ vecXYZ(kmath:GetUpVector(rot)) }, ax, ang)
	local L = { vecXYZ(comp:K2_GetComponentLocation()) }
	local d = RX.rotv(RX.vsub(L, W), ax, ang)
	comp:K2_SetWorldLocationAndRotation(kmath:MakeVector(W[1] + d[1], W[2] + d[2], W[3] + d[3]),
		kmath:MakeRotationFromAxes(kmath:MakeVector(X[1], X[2], X[3]), kmath:MakeVector(Y[1], Y[2], Y[3]),
			kmath:MakeVector(Z[1], Z[2], Z[3])), false, RX.hit(), true)
end

-- WRIST LIMITS (see RX.AIK). The hand's own frame, from the held arm's
-- bones: Fn its forearm line (the wrist less its pose's elbow -- rigid with
-- the hand), T toward the thumb (index knuckle less little-finger knuckle,
-- square to Fn: a fist's knuckle row runs thumb-up), Pn = Fn x T. Read in
-- that frame, the piece's forearm Fs gives the bend: deviation about Pn
-- (+ toward the thumb, - toward the little finger) and flex about T. Past
-- a limit, the forearm direction the clamped angles would need (v1, with
-- the hand as it is) is turned onto Fs -- and that same turn, about the
-- wrist W, is put on the hand, and on the drawn left weapon's mesh (it
-- rides the controller on its own). Before the piece is placed: the piece
-- hangs off the held arm and would be dragged with it. Returns deviation,
-- flex (deg, as asked) and whether it was held back.
function RX.aikWrist(P, side, W, Eh, Fs)
	local C = RX.AIK
	-- Neither hand is moved off its controller unless its arm asks for it.
	if not C.WRIST_LIMIT or C[side].WRIST_LIMIT ~= true then return nil end
	local Fn = RX.vunit(RX.vsub(W, Eh))
	if Fn == nil then return nil end
	local pre = side == "L" and "B_T_L_Finger_" or "B_T_R_Finger_"
	local ki = { vecXYZ(P.arm:GetSocketLocation(pre .. "10")) }
	local kp = { vecXYZ(P.arm:GetSocketLocation(pre .. "40")) }
	local t = RX.vsub(ki, kp)
	local k = RX.vdot(t, Fn)
	local T = RX.vunit({ t[1] - k * Fn[1], t[2] - k * Fn[2], t[3] - k * Fn[3] })
	if T == nil then return nil end
	local Pn = RX.vcross(Fn, T)
	local a, b, c = RX.vdot(Fs, Fn), RX.vdot(Fs, T), RX.vdot(Fs, Pn)
	local dev, fl = math.deg(math.atan(-b, a)), math.deg(math.atan(-c, a))
	local dev2, fl2 = dev, fl
	if C.WRIST_RADIAL ~= nil then dev2 = math.min(dev2, C.WRIST_RADIAL) end
	if C.WRIST_ULNAR ~= nil then dev2 = math.max(dev2, -C.WRIST_ULNAR) end
	if C.WRIST_FLEX ~= nil then fl2 = math.max(-C.WRIST_FLEX, math.min(C.WRIST_FLEX, fl2)) end
	if dev2 == dev and fl2 == fl then return dev, fl, false end
	local fs = RX.vunit({ 1.0, -math.tan(math.rad(dev2)), -math.tan(math.rad(fl2)) })
	local v1 = { Fn[1] * fs[1] + T[1] * fs[2] + Pn[1] * fs[3], Fn[2] * fs[1] + T[2] * fs[2] + Pn[2] * fs[3],
	             Fn[3] * fs[1] + T[3] * fs[2] + Pn[3] * fs[3] }
	local ax, sn = RX.vunit(RX.vcross(v1, Fs))
	if ax == nil then return dev, fl, false end
	local ang = math.atan(sn, RX.vdot(v1, Fs))
	RX.turnAbout(P.arm, W, ax, ang)
	if side == "L" and not ZZM_sheathed and ZZM_mesh ~= nil and valid(ZZM_mesh) then
		RX.turnAbout(ZZM_mesh, W, ax, ang)
	end
	return dev, fl, true
end

-- The two-bone solve for one arm.
-- 1. The plain solve: the elbow on the side the held hand's roll gives
--    (ROLL_FOLLOW; POLE otherwise) of the shoulder-hand line; out of reach,
--    the piece grows up to STRETCH, then its shoulder end slides toward the
--    hand.
-- 2. WRIST SHARE: past SHARE_FREE, the forearm turns part of the way toward
--    the line the held hand's own forearm takes in its pose (where the
--    gauntlet sits right in the cuff), the elbow moving to suit -- so the
--    seam at the wrist bends less. Backed off if it would bend the elbow
--    backwards, or move the arm's top more than SLIDE_OUT out from under the
--    pauldron or SLIDE_IN into it.
-- 3. The pose showing now is the bend set LAST frame (SetPosition takes
--    effect at the next animation update), so the piece is placed for that
--    bend: forearm exactly on the chosen line, hand exactly on the held
--    hand; any error goes to the shoulder end. The bend wanted now is set
--    for the next frame.
function RX.aikSolve(B, side)
	local P, K, C = RX.aik[side], RX.aikCal[side], RX.AIK
	if P == nil or not P.live or K == nil then return end
	if not valid(P.comp) or not valid(P.arm) then return end
	local o, _, f, r = RX.bodyFrame()
	if o == nil then return end
	local SC = C[side]
	local W = { vecXYZ(P.arm:GetSocketLocation(SC.BONES[3])) }
	local Eh = { vecXYZ(P.arm:GetSocketLocation(SC.BONES[2])) }
	local Ah = { vecXYZ(P.arm:GetSocketLocation(SC.BONES[1])) }
	local S = { vecXYZ(B.torso:GetSocketLocation(SC.BONES[1])) }
	local sh = SC.SHOULDER_SHIFT
	S[1] = S[1] + f[1] * sh[1] + r[1] * sh[2]
	S[2] = S[2] + f[2] * sh[1] + r[2] * sh[2]
	S[3] = S[3] + sh[3]
	local n, d = RX.vunit(RX.vsub(W, S))
	if n == nil then return end
	local lu, lf = K.lu, K.lf
	-- s: the piece's world scale -- VIEW_SCALE, stretched when out of reach.
	-- Every length below is s times the piece's own.
	local kv = C.VIEW_SCALE
	local s = kv * math.max(1.0, math.min(C.STRETCH, d / (kv * (lu + lf))))
	-- 1. The plain solve.
	local dd = math.max(K.dmin, math.min(d / s, lu + lf))
	local ca = math.max(-1.0, math.min(1.0, (lu * lu + dd * dd - lf * lf) / (2.0 * lu * dd)))
	local sa = math.sqrt(1.0 - ca * ca)
	local pl = SC.POLE
	local p = { f[1] * pl[1] + r[1] * pl[2], f[2] * pl[1] + r[2] * pl[2], pl[3] }
	local k = RX.vdot(p, n)
	p = RX.vunit({ p[1] - k * n[1], p[2] - k * n[2], p[3] - k * n[3] }) or P.pole
	if p == nil then return end
	-- ROLL: the side the held arm's own elbow hinge puts the elbow (a hinge X
	-- square to the shoulder-hand line comes from the pole n x X). Faded out
	-- as that hinge lines up with the shoulder-hand line and stops saying.
	local Hn = RX.vunit(RX.vcross(RX.vsub(Eh, Ah), RX.vsub(W, Eh)))
	if Hn ~= nil and C.ROLL_FOLLOW > 0.0 then
		local kn = RX.vdot(Hn, n)
		local hq, hl = RX.vunit({ Hn[1] - kn * n[1], Hn[2] - kn * n[2], Hn[3] - kn * n[3] })
		if hq ~= nil then
			local ph = RX.vcross(n, hq)
			local m = C.ROLL_FOLLOW * math.max(0.0, math.min(1.0, (hl - 0.1) / 0.25))
			p = RX.vunit({ p[1] * (1.0 - m) + ph[1] * m, p[2] * (1.0 - m) + ph[2] * m, p[3] * (1.0 - m) + ph[3] * m }) or ph
		end
	end
	-- FOREARM FOLLOW (per arm), SIDEWAYS ONLY. Round the shoulder-hand line
	-- n the elbow's side p is an angle: 0 straight down, 90 straight out
	-- (away from the body's middle), past 90 up. The hand's own forearm line
	-- Fh leaning across the body (the gun aimed left, for the right arm) or
	-- out by "lean" turns the elbow FOLLOW_GAIN x that lean round n, out or
	-- in alike, at most FOLLOW_MAX, so the forearm comes round after the
	-- hand; lengths kept, the hand untouched. Only the lean ACROSS
	-- counts: tipping the wrist up or down leaves the forearm where it is
	-- (2026-10-03: lining the forearm up with the hand in every direction
	-- sent the elbow over the top -- the forearm flipped -- whenever the gun
	-- tipped below level). Continuous in the hand's pose throughout.
	local ff = SC.FOREARM_FOLLOW or 0.0
	local Fh = ff > 0.0 and RX.vunit(RX.vsub(W, Eh)) or nil
	if Fh ~= nil then
		local kd = -n[3]
		local dq = RX.vunit({ -kd * n[1], -kd * n[2], -1.0 - kd * n[3] })    -- down, square to n
		local ow = side == "R" and { r[1], r[2], 0.0 } or { -r[1], -r[2], 0.0 }
		local k1, k2 = RX.vdot(ow, n), dq ~= nil and RX.vdot(ow, dq) or 0.0
		local oq2 = dq ~= nil and RX.vunit({ ow[1] - k1 * n[1] - k2 * dq[1], ow[2] - k1 * n[2] - k2 * dq[2],
			ow[3] - k1 * n[3] - k2 * dq[3] }) or nil                           -- out, square to n and down
		if dq ~= nil and oq2 ~= nil then
			-- Signed: + aimed in across the body, - aimed out; the same swing
			-- either way (2026-10-03: out-only, up to 100 deg, was "way too
			-- much" and lopsided). A turn of p about n -- dq x oq2 turns down
			-- toward out -- so no angle wraps and nothing can jump.
			local lean = math.deg(math.asin(math.max(-1.0, math.min(1.0, -RX.vdot(Fh, oq2)))))
			local swing = ff * math.max(-C.FOLLOW_MAX, math.min(C.FOLLOW_MAX, C.FOLLOW_GAIN * lean))
			p = RX.vunit(RX.rotv(p, RX.vcross(dq, oq2), math.rad(swing))) or p
		end
	end
	-- Never further IN than straight down (ELBOW_IN_MAX): oq is "out" (away
	-- from the body's middle) square to the shoulder-hand line; the elbow's
	-- side may not lean against it. Past the limit it is put back on it --
	-- the nearer of straight down / straight up, which is where it was going.
	local out = { -r[1], -r[2], 0.0 }
	if side == "R" then out = { r[1], r[2], 0.0 } end
	local ko = RX.vdot(out, n)
	local oq = RX.vunit({ out[1] - ko * n[1], out[2] - ko * n[2], out[3] - ko * n[3] })
	if oq ~= nil then
		local lim = -math.sin(math.rad(C.ELBOW_IN_MAX))
		local po = RX.vdot(p, oq)
		if po < lim then
			local q = RX.vunit({ p[1] + (lim - po) * oq[1], p[2] + (lim - po) * oq[2], p[3] + (lim - po) * oq[3] })
			if q == nil then
				-- Straight in: down's side of the boundary.
				local kd = RX.vdot({ 0.0, 0.0, -1.0 }, n)
				q = RX.vunit({ -kd * n[1], -kd * n[2], -1.0 - kd * n[3] }) or oq
			end
			p = q
		end
	end
	P.pole = p
	local Hp = RX.vunit(RX.vcross(p, n))
	if Hp == nil then return end
	local E0 = {}
	for i = 1, 3 do E0[i] = W[i] - n[i] * s * dd + s * lu * (ca * n[i] + sa * p[i]) end
	local F0 = RX.vunit(RX.vsub(W, E0)) or n
	-- 2. The wrist share.
	local Fn = RX.vunit(RX.vsub(W, Eh))
	local shift, ax = 0.0, nil
	if Fn ~= nil and C.WRIST_SHARE > 0.0 then
		local sw
		ax, sw = RX.vunit(RX.vcross(F0, Fn))
		if ax ~= nil then
			local over = math.atan(sw, RX.vdot(F0, Fn)) - math.rad(C.SHARE_FREE)
			shift = math.max(0.0, math.min(C.WRIST_SHARE * over, math.rad(C.WRIST_SHARE_MAX)))
		end
	end
	-- Each try: forearm, upper arm, hinge, the arm top's slide, and how far
	-- OUT of the shoulder-hand line the elbow sits (cm; negative = in).
	local function at(a)
		local Fs = a > 0.0 and RX.rotv(F0, ax, a) or F0
		local ev = { W[1] - Fs[1] * s * lf - S[1], W[2] - Fs[2] * s * lf - S[2], W[3] - Fs[3] * s * lf - S[3] }
		local Us, le = RX.vunit(ev)
		if Us == nil then Us, le = n, s * lu end
		return Fs, Us, RX.vcross(Us, Fs), le - s * lu, oq ~= nil and RX.vdot(ev, oq) or 0.0
	end
	local _, _, _, base, baseOut = at(0.0)
	local function fits(Hc, slide, outw)
		return RX.vdot(Hc, Hp) >= 0.0 and slide <= math.max(0.0, base) + C.SLIDE_OUT
			and slide >= math.min(0.0, base) - C.SLIDE_IN and outw >= math.min(0.0, baseOut) - 0.5
	end
	local Fs, Us, Hc, slide, outw = at(shift)
	if shift > 0.0 and not fits(Hc, slide, outw) then
		local lo, hi = 0.0, shift
		for _ = 1, 6 do
			local mid = (lo + hi) * 0.5
			local _, _, h2, s2, o2 = at(mid)
			if fits(h2, s2, o2) then lo = mid else hi = mid end
		end
		shift = lo
		Fs, Us, Hc, slide, outw = at(shift)
	end
	-- The hinge: the solved one, eased onto the pole's near straight (where
	-- the solved one is undefined), kept square to the forearm.
	local kq = RX.vdot(Hp, Fs)
	local Hs = RX.vunit({ Hc[1] + 0.05 * (Hp[1] - kq * Fs[1]), Hc[2] + 0.05 * (Hp[2] - kq * Fs[2]),
	                      Hc[3] + 0.05 * (Hp[3] - kq * Fs[3]) })
	if Hs == nil then return end
	local want = math.deg(math.atan(RX.vdot(Hc, Hs), RX.vdot(Us, Fs)))
	want = math.max(0.0, math.min(C.THETA_MAX, want))
	-- The wrist limits: the hand turned back about the wrist (W does not
	-- move, so the forearm above stands), before the piece is placed.
	local okW, wdev, wfl, wheld = pcall(RX.aikWrist, P, side, W, Eh, Fs)
	if not okW and not RX.wristLimErr then
		RX.wristLimErr = true
		log("arm ik %s: wrist limit failed: %s", side, tostring(wdev))
	end
	-- 3. Placed for the bend showing.
	local Ush = RX.rotv(Fs, Hs, -math.rad(P.theta or 0.0))
	local X = RX.vcross(Ush, Hs)
	local e1, e2, e3 = K.u, K.h, K.w
	local col = {}
	for j = 1, 3 do
		col[j] = { Ush[1] * e1[j] + Hs[1] * e2[j] + X[1] * e3[j],
		           Ush[2] * e1[j] + Hs[2] * e2[j] + X[2] * e3[j],
		           Ush[3] * e1[j] + Hs[3] * e2[j] + X[3] * e3[j] }
	end
	local A, loc, top = K.A, {}, {}
	for i = 1, 3 do
		top[i] = W[i] - Fs[i] * s * lf - Ush[i] * s * lu
		loc[i] = top[i] - s * (col[1][i] * A[1] + col[2][i] * A[2] + col[3][i] * A[3])
	end
	local rot = kmath:MakeRotationFromAxes(kmath:MakeVector(col[1][1], col[1][2], col[1][3]),
		kmath:MakeVector(col[2][1], col[2][2], col[2][3]), kmath:MakeVector(col[3][1], col[3][2], col[3][3]))
	P.comp:K2_SetWorldLocationAndRotation(kmath:MakeVector(loc[1], loc[2], loc[3]), rot, false, RX.hit(), true)
	if math.abs(s - (P.scale or 1.0)) > 0.002 then
		P.comp:SetWorldScale3D(kmath:MakeVector(s, s, s))
		P.scale = s
	end
	if math.abs(want - (P.theta or -1.0)) > 0.05 then
		P.comp:SetPosition(want / C.THETA_MAX * K.len, false)
		P.theta = want
	end
	if C.DEBUG then
		local L = P.dbg
		if L == nil then
			L = { t = ZZM_time, d0 = 999.0, d1 = 0.0, off = 0.0, s1 = 1.0, b0 = 999.0, b1 = 0.0, sh = 0.0, seam = 0.0 }
			P.dbg = L
		end
		L.d0, L.d1 = math.min(L.d0, d), math.max(L.d1, d)
		L.off, L.s1 = math.max(L.off, wDist(top, S)), math.max(L.s1, s / kv)
		L.b0, L.b1 = math.min(L.b0, want), math.max(L.b1, want)
		L.sh = math.max(L.sh, math.deg(shift))
		if Fn ~= nil then
			L.seam = math.max(L.seam, math.deg(math.acos(math.max(-1.0, math.min(1.0, RX.vdot(Fs, Fn))))))
		end
		if okW and wdev ~= nil then
			L.dv0, L.dv1 = math.min(L.dv0 or 999.0, wdev), math.max(L.dv1 or -999.0, wdev)
			L.fl = math.max(L.fl or 0.0, math.abs(wfl))
			if wheld then L.held = (L.held or 0) + 1 end
		end
		if ZZM_time - L.t >= 1.0 then
			-- The wrist part only for an arm the wrist limits are on.
			local wl = L.dv0 == nil and "" or string.format("; wrist asked: deviation %.0f..%.0f, flex up to "
				.. "%.0f deg, held back %d frames", L.dv0, L.dv1, L.fl or 0.0, L.held or 0)
			log("arm ik %s: shoulder->hand %.0f..%.0f cm (arm %.0f), stretch up to %.2f, top up to %.0f cm off "
				.. "its joint, elbow %.0f..%.0f deg, wrist seam up to %.0f deg after sharing up to %.0f%s",
				side, L.d0, L.d1, lu + lf, L.s1, L.off, L.b0, L.b1, L.seam, L.sh, wl)
			P.dbg = nil
		end
	end
end

--==========================================================================
-- REVERSE GRIP + POMMEL BASH (Force Sword)
--==========================================================================
-- RX.revOn: the sword is the other way round in the fist. RX.revT: when the
-- left thumbrest went down (nil = not touching); RX.rT: when the right one
-- did. RX.stuns: { actor, anim, untilT } -- stealers held still now.

-- Hamilton product of two (w, x, y, z) quaternions.
function RX.qmul(a, b)
	return { a[1] * b[1] - a[2] * b[2] - a[3] * b[3] - a[4] * b[4],
	         a[1] * b[2] + a[2] * b[1] + a[3] * b[4] - a[4] * b[3],
	         a[1] * b[3] - a[2] * b[4] + a[3] * b[1] + a[4] * b[2],
	         a[1] * b[4] + a[2] * b[3] - a[3] * b[2] + a[4] * b[1] }
end

-- A grip entry turned half a turn about RX.REV.FIST round RX.REV.AXIS (sword
-- mesh space). UEVR places a part at rotation H * inv(Q) and position
-- controller - B(G * loc), B taking its (glm) axes to UE's: (x, y, z) ->
-- (-z, x, y). Turning the part by F about c in its own frame is then
-- Q' = inv(F) * Q and loc' = F^T (loc - B^T (c - F c)); for a half turn F's
-- glm form is (0, B^T axis), F^T = F, and c - F c = twice c square to the
-- axis. Cached on the entry.
function RX.revEntry(entry)
	if entry._rev ~= nil then return entry._rev end
	local A, c = RX.REV.AXIS, RX.REV.FIST
	local ag = { A[2], A[3], -A[1] }                        -- UE -> glm
	local q2 = RX.qmul({ 0.0, -ag[1], -ag[2], -ag[3] }, entry.quat)
	local ca = c[1] * A[1] + c[2] * A[2] + c[3] * A[3]
	local cp = { c[1] - ca * A[1], c[2] - ca * A[2], c[3] - ca * A[3] }
	local v = { 2.0 * cp[2], 2.0 * cp[3], -2.0 * cp[1] }     -- B^T (c - F c)
	local l = entry.loc
	local w = { l[1] - v[1], l[2] - v[2], l[3] - v[3] }
	local k = 2.0 * (ag[1] * w[1] + ag[2] * w[2] + ag[3] * w[3])
	entry._rev = { attach = entry.attach, armGrip = entry.armGrip, quat = q2,
		loc = { k * ag[1] - w[1], k * ag[2] - w[2], k * ag[3] - w[3] } }
	log("reverse grip for %s: quat %.4f %.4f %.4f %.4f, loc %.2f %.2f %.2f", tostring(entry.attach),
		q2[1], q2[2], q2[3], q2[4], entry._rev.loc[1], entry._rev.loc[2], entry._rev.loc[3])
	return entry._rev
end

-- The grip applyLeftHand writes for the weapon mesh.
function RX.revGrip(cls, entry)
	if RX.revOn and RX.REV.ENABLED and RX.REV.CLASSES[cls] and entry.quat ~= nil and entry.loc ~= nil then
		return RX.revEntry(entry)
	end
	return entry
end

-- A thumbrest's touch. Under OpenXR the left source is a null pointer that
-- arrives as nil and still means the LEFT hand -- never "left and L or R".
function RX.thumb(left)
	if RX.trActL == nil then
		pcall(function()
			local vr = uevr.params.vr
			RX.trActL = vr.get_action_handle("/actions/default/in/ThumbrestTouchLeft")
			RX.trActR = vr.get_action_handle("/actions/default/in/ThumbrestTouchRight")
		end)
	end
	local act = RX.trActR
	if left then act = RX.trActL end
	if act == nil then return false end
	local ok, r = pcall(function()
		local vr = uevr.params.vr
		local src
		if left then src = vr.get_left_joystick_source() else src = vr.get_right_joystick_source() end
		return vr.is_action_active(act, src)
	end)
	return ok and r == true
end

-- Every tick: a brush of the left thumbrest turns the drawn sword round.
-- A new left weapon starts the right way round.
function RX.revTick(cls)
	local C = RX.REV
	if cls ~= "" and cls ~= RX.revCls then
		if RX.revOn then log("reverse grip off (new weapon %s)", cls) end
		RX.revCls, RX.revOn = cls, false
	end
	local l, r = RX.thumb(true), RX.thumb(false)
	if r and not RX.rWas then RX.rT = ZZM_time end
	RX.rWas = r
	if l then
		if RX.revT == nil then RX.revT = ZZM_time end
		return
	end
	local t0 = RX.revT
	RX.revT = nil
	if t0 == nil or ZZM_time - t0 > C.BRUSH_MAX then return end
	-- The Psygate chord: the right thumbrest went down along with it.
	if r and RX.rT ~= nil and math.abs(RX.rT - t0) <= C.CHORD then return end
	if not (C.ENABLED and C.CLASSES[cls] and not ZZM_sheathed and LI.gameplay()) then return end
	if ZZM_time < (RX.revCool or 0.0) then return end
	RX.revCool = ZZM_time + C.COOLDOWN
	RX.revOn = not RX.revOn
	RX.revFlipT = ZZM_time   -- the heft lets the blade swing round to it
	LI.haptic(C.HAPTIC)
	log("reverse grip %s (thumbrest brush, %.2f s)", RX.revOn and "ON" or "off", ZZM_time - t0)
end

-- Stun one stealer: the game's shove, a knock back the way the pommel went,
-- and its AI held still for STUN_TIME (extended if it is already stunned).
function RX.stun(pawn, t, dx, dy, speed, mesh)
	local C = RX.BASH
	local s = t.actor
	local h = math.sqrt(dx * dx + dy * dy)
	if h < 0.1 then
		pcall(function() dx, dy = vecXYZ(pawn:GetActorForwardVector()) end)
		h = math.max(0.001, math.sqrt(dx * dx + dy * dy))
	end
	dx, dy = dx / h, dy / h
	local okP, errP = pcall(function() s:PushThisStealer(pawn, kmath:MakeVector(dx, dy, 0.0), C.CHARGE) end)
	if C.KNOCKBACK > 0.0 then
		pcall(function() s:LaunchCharacter(kmath:MakeVector(dx * C.KNOCKBACK, dy * C.KNOCKBACK, C.KNOCK_UP), true, true) end)
	end
	local anim = nil
	pcall(function() anim = s.Mesh.AnimScriptInstance end)
	RX.stuns = RX.stuns or {}
	local entry = nil
	for _, e in ipairs(RX.stuns) do
		if sameObject(e.actor, s) then entry = e end
	end
	if entry == nil then
		if anim ~= nil then pcall(function() anim:LockAIResources(true, true) end) end
		table.insert(RX.stuns, { actor = s, anim = anim, untilT = ZZM_time + C.STUN_TIME })
	else
		entry.untilT = ZZM_time + C.STUN_TIME
	end
	local bone = ""
	pcall(function() bone = t.bone:to_string() end)
	for _, e in ipairs(C.SOUNDS) do
		local cue = LI.sound(e[1])
		if cue ~= nil then spawnSoundOn(t.mesh or mesh, bone, cue, e[2], e[3] * (0.95 + 0.1 * math.random())) end
	end
	LI.haptic(C.HAPTIC)
	log("pommel bash: %s stunned for %.1f s (pommel at %.0f cm/s, %s bone %s)%s", className(s), C.STUN_TIME, speed,
		RX.revOn and "reverse grip," or "", bone, okP and "" or (" -- shove failed: " .. tostring(errP)))
end

-- Every tick: let stunned stealers go when their time is up.
function RX.stunTick()
	local L = RX.stuns
	if L == nil then return end
	for i = #L, 1, -1 do
		local e = L[i]
		if ZZM_time >= e.untilT or not valid(e.actor) then
			if e.anim ~= nil and valid(e.anim) and valid(e.actor) then
				pcall(function() e.anim:UnlockAIResources(true, true) end)
			end
			table.remove(L, i)
		end
	end
end

-- Every tick with the sword drawn: the pommel driven pommel-first into a
-- stealer is a bash.
function RX.bashTick(pawn, lw, mesh, cls, delta)
	local C = RX.BASH
	if not (C.ENABLED and C.CLASSES[cls] and mesh ~= nil and pawn ~= nil and not ZZM_sheathed and LI.gameplay()
		and ZZGrab ~= nil and ZZGrab.findOnBlade ~= nil) or delta <= 0.0 then
		RX.bashPrev = nil
		return
	end
	local xf = mesh:K2_GetComponentToWorld()
	local px, py, pz = vecXYZ(kmath:TransformLocation(xf, kmath:MakeVector(C.POMMEL[1], C.POMMEL[2], C.POMMEL[3])))
	local hx, hy, hz = vecXYZ(kmath:TransformLocation(xf, kmath:MakeVector(C.HILT[1], C.HILT[2], C.HILT[3])))
	local prev = RX.bashPrev
	RX.bashPrev = { px, py, pz }
	if prev == nil or ZZM_time < (RX.bashCool or 0.0) then return end
	if ZZGrab.isImpaling ~= nil and ZZGrab.isImpaling() then return end
	local pvx, pvy, pvz = 0.0, 0.0, 0.0
	pcall(function() pvx, pvy, pvz = vecXYZ(pawn:GetVelocity()) end)
	local vx = (px - prev[1]) / delta - pvx
	local vy = (py - prev[2]) / delta - pvy
	local vz = (pz - prev[3]) / delta - pvz
	local s = math.sqrt(vx * vx + vy * vy + vz * vz)
	if s < C.SPEED or s > C.JUMP_SPEED then return end
	-- Pommel first: moving within LEAD_ANGLE of the way it points.
	local dx, dy, dz = px - hx, py - hy, pz - hz
	local dl = math.sqrt(dx * dx + dy * dy + dz * dz)
	if dl < 1.0 then return end
	dx, dy, dz = dx / dl, dy / dl, dz / dl
	if vx * dx + vy * dy + vz * dz < s * math.cos(math.rad(C.LEAD_ANGLE)) then return end
	local t = ZZGrab.findOnBlade(hx, hy, hz, px + dx * C.LEAD, py + dy * C.LEAD, pz + dz * C.LEAD, C.REACH)
	if t == nil then
		if C.DEBUG and ZZM_time - (RX.bashLogT or -9.0) > 0.5 then
			RX.bashLogT = ZZM_time
			log("pommel bash: pommel at %.0f cm/s, nothing in reach", s)
		end
		return
	end
	RX.bashCool = ZZM_time + C.COOLDOWN
	RX.stun(pawn, t, vx, vy, s, mesh)
end

--==========================================================================
-- SWORD HEFT
--==========================================================================
-- RX.heftMesh: the drawn sword's mesh this tick (nil = none). RX.heft:
-- { mesh, q = shown rotation (w, x, y, z), w = angular velocity (rad/s,
-- world), qt = last target, t }. Quaternions here are w-first; RX.qmul is
-- the product.

function RX.qnorm(q)
	local l = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
	if l < 1e-9 then return { 1.0, 0.0, 0.0, 0.0 } end
	return { q[1] / l, q[2] / l, q[3] / l, q[4] / l }
end

-- The rotation whose X, Y, Z axes (UE: forward, right, up) are these.
function RX.qFromAxes(X, Y, Z)
	local m00, m01, m02 = X[1], Y[1], Z[1]
	local m10, m11, m12 = X[2], Y[2], Z[2]
	local m20, m21, m22 = X[3], Y[3], Z[3]
	local tr = m00 + m11 + m22
	local w, x, y, z
	if tr > 0.0 then
		local s = math.sqrt(tr + 1.0) * 2.0
		w, x, y, z = 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1.0 + m00 - m11 - m22) * 2.0
		w, x, y, z = (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
	elseif m11 > m22 then
		local s = math.sqrt(1.0 + m11 - m00 - m22) * 2.0
		w, x, y, z = (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
	else
		local s = math.sqrt(1.0 + m22 - m00 - m11) * 2.0
		w, x, y, z = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
	end
	return RX.qnorm({ w, x, y, z })
end

-- Its X, Y, Z axes.
function RX.qAxes(q)
	local w, x, y, z = q[1], q[2], q[3], q[4]
	return { 1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y + w * z), 2.0 * (x * z - w * y) },
		{ 2.0 * (x * y - w * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z + w * x) },
		{ 2.0 * (x * z + w * y), 2.0 * (y * z - w * x), 1.0 - 2.0 * (x * x + y * y) }
end

-- The turn from a to b as a rotation vector (axis * angle, radians, world),
-- the short way round.
function RX.qDelta(a, b)
	local d = RX.qmul(b, { a[1], -a[2], -a[3], -a[4] })
	if d[1] < 0.0 then d = { -d[1], -d[2], -d[3], -d[4] } end
	local s = math.sqrt(d[2] * d[2] + d[3] * d[3] + d[4] * d[4])
	if s < 1e-9 then return { 0.0, 0.0, 0.0 }, 0.0 end
	local ang = 2.0 * math.atan(s, d[1])
	return { d[2] / s * ang, d[3] / s * ang, d[4] / s * ang }, ang
end

-- q turned by the rotation vector v.
function RX.qTurn(q, v)
	local ang = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
	if ang < 1e-9 then return q end
	local s = math.sin(ang * 0.5) / ang
	return RX.qnorm(RX.qmul({ math.cos(ang * 0.5), v[1] * s, v[2] * s, v[3] * s }, q))
end

-- UEVR's own attachment smoothing off while HEFT is on (put back if not).
-- What it was is kept in a global, so a script reload never takes our
-- "false" for the user's own setting.
ZZM_lerpWas = ZZM_lerpWas
function RX.heftLerp()
	local C = RX.HEFT
	local vr = uevr.params.vr
	local key = "UObjectHook_AttachLerpEnabled"
	local want = C.ENABLED and C.UEVR_LERP_OFF
	local ok, cur = pcall(function() return vr:get_mod_value(key) end)
	if not ok or type(cur) ~= "string" then return end
	if want then
		if cur:sub(1, 4) == "true" then
			if ZZM_lerpWas == nil then ZZM_lerpWas = "true" end
			pcall(function() vr.set_mod_value(key, "false") end)
			log("heft: UEVR's attachment smoothing off (the sword's weight replaces it; the left hand no longer trails)")
		end
	elseif ZZM_lerpWas ~= nil then
		pcall(function() vr.set_mod_value(key, ZZM_lerpWas) end)
		log("heft: UEVR's attachment smoothing back to %s", ZZM_lerpWas)
		ZZM_lerpWas = nil
	end
end

-- In the view callback, after UEVR has put the sword where the controller
-- says: the shown sword turned the spring's way about the fist instead.
function RX.heftView()
	local C = RX.HEFT
	local mesh = RX.heftMesh
	if not C.ENABLED or mesh == nil or not valid(mesh) then
		RX.heft = nil
		return
	end
	local X, Y, Z = { vecXYZ(mesh:GetForwardVector()) }, { vecXYZ(mesh:GetRightVector()) }, { vecXYZ(mesh:GetUpVector()) }
	local qt = RX.qFromAxes(X, Y, Z)
	local F = RX.REV.FIST
	local px, py, pz = vecXYZ(kmath:TransformLocation(mesh:K2_GetComponentToWorld(), kmath:MakeVector(F[1], F[2], F[3])))
	local H = RX.heft
	local dt = H ~= nil and (ZZM_time - H.t) or 0.0
	local flipping = ZZM_time - (RX.revFlipT or -9.0) < 0.4
	if H == nil or not sameObject(H.mesh, mesh) or dt <= 0.0 or dt > 0.1 then
		H = { mesh = mesh, q = qt, w = { 0.0, 0.0, 0.0 }, qt = qt, t = ZZM_time }
		RX.heft = H
		return
	end
	-- A target that leapt (a snap turn, a teleport): no swing to catch up on.
	-- The reverse grip's half turn is the exception: that one the blade
	-- swings round to, about the fist.
	local _, jumped = RX.qDelta(H.qt, qt)
	if jumped > math.rad(40.0) and not flipping then
		H.q, H.w = qt, { 0.0, 0.0, 0.0 }
	end
	H.qt, H.t = qt, ZZM_time
	-- Spring-damper on the shown rotation: w += (kp e - kd w) dt; q turns by w dt.
	local hz = C.WEIGHT_HZ * ((ZZM_lit and C.LIT) or 1.0)
	local wn = 2.0 * math.pi * hz
	local kp, kd = wn * wn, 2.0 * C.DAMPING * wn
	local steps = math.max(1, math.ceil(dt * wn / 0.3))
	local h = dt / steps
	for _ = 1, steps do
		local e = RX.qDelta(H.q, qt)
		for i = 1, 3 do H.w[i] = H.w[i] + (kp * e[i] - kd * H.w[i]) * h end
		H.q = RX.qTurn(H.q, { H.w[1] * h, H.w[2] * h, H.w[3] * h })
	end
	-- Never more than MAX_LAG behind (save while swinging round to a reversed grip).
	local e, lag = RX.qDelta(H.q, qt)
	local lim = math.rad(C.MAX_LAG)
	if lag > lim and not flipping then
		local k = (lag - lim) / lag
		H.q = RX.qTurn(H.q, { e[1] * k, e[2] * k, e[3] * k })
	end
	-- Placed: turned about the fist, which stays where the grip put it.
	local A, B, Cz = RX.qAxes(H.q)
	local s = RX.AIK.VIEW_SCALE
	local loc = kmath:MakeVector(px - s * (A[1] * F[1] + B[1] * F[2] + Cz[1] * F[3]),
		py - s * (A[2] * F[1] + B[2] * F[2] + Cz[2] * F[3]), pz - s * (A[3] * F[1] + B[3] * F[2] + Cz[3] * F[3]))
	local rot = kmath:MakeRotationFromAxes(kmath:MakeVector(A[1], A[2], A[3]), kmath:MakeVector(B[1], B[2], B[3]),
		kmath:MakeVector(Cz[1], Cz[2], Cz[3]))
	mesh:K2_SetWorldLocationAndRotation(loc, rot, false, RX.hit(), true)
	if C.DEBUG then
		H.peak = math.max(H.peak or 0.0, math.deg(lag))
		if ZZM_time - (H.logT or 0.0) >= 2.0 then
			if H.peak > 1.0 then log("heft: the blade trailed up to %.0f deg these 2 s", H.peak) end
			H.logT, H.peak = ZZM_time, 0.0
		end
	end
end

--==========================================================================
-- SWING SOUND
--==========================================================================

-- Rising edge on left-hand speed with MainHandler's thresholds, so the
-- whoosh lands with the attack trigger rather than with the canned attack.
-- Plays from whatever rides the controller: the weapon mesh, or the arm for
-- fist and claw. Louder for a harder swing.
local function applySwingSound(pawn, lw, cls)
	if not SWING_SOUND_ON_MOTION then return end
	local spd = PosDiffSecondaryHand or 0.0   -- owned by MeleePower
	if spd < SWING_SPEED_OFF then ZZM_swingArmed = true end
	if not ZZM_swingArmed or spd < SWING_SPEED_ON then return end
	ZZM_swingArmed = false
	-- An open hand, a reach for a grab, a stealer swung about: not a weapon.
	if ZZMelee_LeftSwings == false then return end
	if ZZM_swingCue == nil or lw == nil then return end
	if RESPECT_MENUS and (isMenu == true or isCinematic == true) then return end

	local entry = LEFT_WEAPONS[cls]
	local target, socket = nil, ""
	if (entry ~= nil and entry.attach == "arm") or ZZM_sheathed then
		pcall(function() target = pawn.LArm end)
		socket = "L_Hand"
	else
		pcall(function() target = lw.MeleeWeapon end)
	end
	if target == nil then return end

	local k = (spd - SWING_SPEED_ON) / math.max(SWING_SPEED_FULL - SWING_SPEED_ON, 1.0)
	local vol = SWING_VOLUME * math.max(0.4, math.min(1.0, 0.4 + 0.6 * k))
	spawnSoundOn(target, socket, ZZM_swingCue, vol, 0.95 + 0.1 * math.random())
end

--==========================================================================
-- LEFT INPUT -- swing, LB, holster (see the LI config block)
--==========================================================================

function LI.gameplay()
	return isCinematic ~= true and isLTScreen ~= true
end

-- The swing timings were tuned against VRClock, which both MeleePower and
-- MainHandler advance every tick -- so it runs at twice real time and
-- LIGHT_HOLD/HEAVY_HOLD are really half what they say. Kept on that clock
-- so the attacks feel exactly as before the move.
function LI.clock()
	return VRClock or ZZM_time
end

-- "weapon"  a weapon in hand (or no known left weapon): parry and attacks
-- "empty"   a holsterable weapon on the back: bare hand
-- "fist"    Power Fist: a hand that is also the weapon
function LI.mode(cls)
	if LI.HOLSTERABLE[cls] then return ZZM_sheathed and "empty" or "weapon" end
	if LI.GRAB_HANDS[cls] then return "fist" end
	return "weapon"
end

function LI.haptic(h)
	pcall(function()
		local vr = uevr.params.vr
		vr.trigger_haptic_vibration(0.0, h[1], 1000.0, h[2], vr.get_left_joystick_source())
	end)
end

-- a * b for quaternions given as x, y, z, w.
function LI.qmul(ax, ay, az, aw, bx, by, bz, bw)
	return aw * bx + ax * bw + ay * bz - az * by,
	       aw * by - ax * bz + ay * bw + az * bx,
	       aw * bz + ax * by - ay * bx + az * bw,
	       aw * bw - ax * bx - ay * by - az * bz
end

LI.hp, LI.hq = UEVR_Vector3f.new(), UEVR_Quaternionf.new()
LI.lp, LI.lq = UEVR_Vector3f.new(), UEVR_Quaternionf.new()

-- Left controller relative to the headset, in the headset's own frame
-- (conj(q) * v * q, as GestureDPad does it): +x right, +y up, +z behind.
function LI.handVsHead()
	local ok, x, y, z = pcall(function()
		local vr = uevr.params.vr
		vr.get_pose(vr.get_hmd_index(), LI.hp, LI.hq)
		vr.get_pose(vr.get_left_controller_index(), LI.lp, LI.lq)
		local q = LI.hq
		local tx, ty, tz, tw = LI.qmul(-q.x, -q.y, -q.z, q.w,
			LI.lp.x - LI.hp.x, LI.lp.y - LI.hp.y, LI.lp.z - LI.hp.z, 0.0)
		local rx, ry, rz = LI.qmul(tx, ty, tz, tw, q.x, q.y, q.z, q.w)
		return rx, ry, rz
	end)
	if not ok then return nil end
	return x, y, z
end

-- In the holster zone, grown by margin metres on every side.
function LI.inHolsterZone(x, y, z, margin)
	local d = math.sqrt(x * x + y * y + z * z)
	return d <= LI.HOLSTER_MAX_DIST + margin and z >= LI.HOLSTER_BEHIND - margin
		and y >= LI.HOLSTER_MIN_UP - margin, d
end

function LI.behindHead()
	local x, y, z = LI.handVsHead()
	if x == nil then return false end
	local hit, d = LI.inHolsterZone(x, y, z, 0.0)
	if LI.HOLSTER_DEBUG then
		log("LB press, hand vs head: right %.2f up %.2f back %.2f (%.2f m) -> %s",
			x, y, z, d, hit and "holster zone" or "not holster")
	end
	return hit
end

-- The find-it-by-feel bump (HOLSTER_ZONE_BUMP), every tick a holsterable
-- weapon is equipped. Not while holding something: that hand is busy.
ZZM_inZone = ZZM_inZone or false
function LI.zoneBump(cls)
	if not LI.HOLSTER_ZONE_BUMP or not LI.HOLSTERABLE[cls]
		or (ZZGrab ~= nil and ZZGrab.isHolding()) then
		ZZM_inZone = false
		return
	end
	local x, y, z = LI.handVsHead()
	if x == nil then return end
	if ZZM_inZone then
		ZZM_inZone = LI.inHolsterZone(x, y, z, LI.HOLSTER_ZONE_MARGIN)
	elseif LI.inHolsterZone(x, y, z, 0.0) then
		ZZM_inZone = true
		LI.haptic(LI.HAPTIC_ZONE)
	end
end

-- Everything the sword or fist makes, put out but kept: the light actor
-- stays bound (hidden, on the hidden blade) so drawing needs no rebind.
-- Destroying it here is what hung the game 2026-09-29: K2_DestroyActor on
-- the PointLight from this pre-engine-tick callback left the game thread
-- spinning in a wait inside the engine (stack: Lua -> ProcessEvent ->
-- K2_DestroyActor -> ... -> Sleep) with every other thread idle.
function LI.douse()
	ZZM_lit, ZZM_wasLit, ZZM_level = false, false, 0.0
	applyLight(ZZM_light, 0.0)
	applyLight(ZZM_armLight, 0.0)
	silence()
	stopBoost()
end

-- A sound asset by full name, from UObjectHook's per-class list (a
-- find_uobject miss scans every object, ~225 ms). Each answer, found or
-- not, is kept until the pawn changes (a new level loads other sounds).
LI.sndCache, LI.sndPawn, LI.sndLogged = {}, nil, {}
function LI.sound(full)
	local c = LI.sndCache[full]
	if c == false then return nil end
	if c ~= nil and valid(c) then return c end
	local clsName, objName = full:match("^(%S+) .-%.([^%.]+)$")
	local found = false
	pcall(function()
		local cls = api:find_uobject("Class /Script/Engine." .. clsName)
		for _, o in ipairs(UEVR_UObjectHook.get_objects_by_class(cls, false) or {}) do
			if o:get_fname():to_string() == objName and o:get_full_name() == full then
				found = o
				break
			end
		end
	end)
	LI.sndCache[full] = found
	return found or nil
end

-- SHEATH_SOUNDS at the left hand, for a sheathe (on) or a draw.
function LI.sheathSound(lw, on)
	local kind = LI.SHEATH_KIND[className(lw)]
	local set = kind ~= nil and LI.SHEATH_SOUNDS[kind] or nil
	if set == nil or not resolveStatics() then return end
	local pawn = api:get_local_pawn(0)
	local arm = nil
	pcall(function() arm = pawn.LArm end)
	if arm == nil then return end
	local addr = pawn:get_address()
	if LI.sndPawn ~= addr then LI.sndPawn, LI.sndCache = addr, {} end
	local played = {}
	for _, e in ipairs(on and set.sheathe or set.draw) do
		local cue = nil
		for _, path in ipairs(type(e[1]) == "table" and e[1] or { e[1] }) do
			cue = LI.sound(path)
			if cue ~= nil then break end
		end
		if cue ~= nil and spawnSoundOn(arm, "L_Hand", cue, e[2], (e[3] or 1.0) * (0.96 + math.random() * 0.08)) ~= nil then
			table.insert(played, cue:get_fname():to_string())
		end
	end
	local key = kind .. (on and " sheathe" or " draw")
	if not LI.sndLogged[key] then
		LI.sndLogged[key] = true
		log("%s sound: %s", key, #played > 0 and table.concat(played, " + ") or "nothing loaded")
	end
end

-- Visibility propagates to the blade's particle components and to the light
-- attached to it; LI.douse keeps the light off once it is drawn again.
function LI.setSheathed(lw, on)
	local mesh = nil
	pcall(function() mesh = lw.MeleeWeapon end)
	if mesh ~= nil then pcall(function() mesh:SetVisibility(not on, true) end) end
	LI.douse()
	ZZM_sheathed = on
	ZZM_sheathWeapon = on and lw or nil
	ZZM_lastVis = nil
	LI.haptic(LI.HAPTIC_SHEATHE)
	pcall(LI.sheathSound, lw, on)
	log("%s %s", className(lw), on and "sheathed; the left hand is bare" or "drawn")
end

-- Right mouse (WeaponZoom), edge-triggered, as MainHandler did with LB.
function LI.zoom(on)
	if on == ZZM_zoomDown then return end
	ZZM_zoomDown = on
	if on then
		if SendKeyDown ~= nil then pcall(SendKeyDown, "0x02") end
	elseif SendKeyUp ~= nil then
		pcall(SendKeyUp, "0x02")
	end
end

-- An LB press is judged once, here, and keeps that meaning until release.
function LI.press(pawn, lw, cls, mode)
	if LI.HOLSTERABLE[cls] and LI.behindHead() then
		LI.setSheathed(lw, not ZZM_sheathed)
		ZZM_lbUse = "holster"
	elseif (mode == "empty" or mode == "fist") and ZZGrab ~= nil and ZZGrab.tryGrab(pawn, cls) then
		ZZM_lbUse = "grab"
	elseif mode == "empty" then
		ZZM_lbUse = "reach"   -- still a grab for GRAB_WINDOW s (see LI.tick)
		ZZM_grabUntil = ZZM_time + LI.GRAB_WINDOW
	else
		ZZM_lbUse = "parry"
	end
end

-- throw = false when the release is not the player's (menu, cutscene).
function LI.endPress(throw)
	if ZZM_lbUse == "grab" and ZZGrab ~= nil then
		ZZGrab.release(throw)
		ZZM_mArmed = false   -- the throw must not also start an attack
	end
	ZZM_lbUse = nil
	ZZM_lbPass = false
	LI.zoom(false)
end

function LI.swing(pawn, lw, cls, mode)
	local spd = PosDiffSecondaryHand or 0   -- owned by MeleePower
	local now = LI.clock()
	if spd < LI.MELEE_OFF then ZZM_mArmed = true end
	local holding = ZZGrab ~= nil and ZZGrab.isHolding()

	-- Bare hand: the game still has the (sheathed) weapon equipped, so its
	-- attack must never fire. The fist punches instead -- a fist closed by
	-- LT only; LB is a grab (reaching, holding or missed), never a punch.
	-- ZZ_Grab is asked every tick the fist is closed and lands the punch the
	-- moment the moving fist reaches a stealer (it judges speed, contact and
	-- one-per-swing itself).
	if mode == "empty" then
		ZZM_mState = "idle"
		local fist = (ZZM_lbUse == nil or ZZM_lbUse == "miss") and (ZZM_ltFist or not LI.PUNCH_NEEDS_FIST)
		if fist and not holding and ZZGrab ~= nil then ZZGrab.punch(pawn, lw, cls) end
		return
	end

	-- MainHandler's machine. LB held for anything (parry, grab, holster)
	-- blocks the swing, as its "not lShoulder" did; so does holding.
	local meleeOK = ZZM_lbUse == nil and not holding
	local lt = readLT() or 0

	if ZZM_mState == "idle" then
		if ZZM_mArmed and meleeOK and spd > LI.MELEE_ON then
			ZZM_mState = "pressing"
			ZZM_mT0    = now
			ZZM_mArmed = false
			ZZM_mHeavy = lt > 0
		end
	elseif ZZM_mState == "pressing" then
		local held = now - ZZM_mT0
		-- squeezing LT slightly after the swing begins still counts as heavy
		if not ZZM_mHeavy and held < LI.LIGHT_HOLD and lt > 0 then ZZM_mHeavy = true end
		if held >= (ZZM_mHeavy and LI.HEAVY_HOLD or LI.LIGHT_HOLD) then
			if LI.MELEE_DEBUG then
				log("MELEE %s  held=%.3f  spd=%.1f", ZZM_mHeavy and "HEAVY" or "light", held, spd)
			end
			ZZM_mState = "cooldown"
			ZZM_mT0    = now
		end
	elseif ZZM_mState == "cooldown" then
		if now - ZZM_mT0 > LI.MELEE_CD then ZZM_mState = "idle" end
	end

	if not meleeOK and ZZM_mState == "pressing" then
		ZZM_mState = "cooldown"
		ZZM_mT0    = now
	end
end

function LI.tick(pawn, lw, cls)
	if not ZZMelee_OwnsLeftInput then return end

	-- Menus, cutscenes, no pawn: let go of everything, finish any attack.
	if pawn == nil or not LI.gameplay() then
		if ZZM_lbUse ~= nil then LI.endPress(false) end
		ZZM_lbWas = false
		ZZM_ltFist = false
		ZZM_inZone = false
		ZZMelee_LeftSwings = true
		if ZZM_mState == "pressing" then
			ZZM_mState, ZZM_mT0 = "cooldown", LI.clock()
		elseif ZZM_mState == "cooldown" and LI.clock() - ZZM_mT0 > LI.MELEE_CD then
			ZZM_mState = "idle"
		end
		return
	end

	-- A weapon swap (or respawn) brings the new weapon out in hand.
	if ZZM_sheathed and not sameObject(lw, ZZM_sheathWeapon) then
		ZZM_sheathed, ZZM_sheathWeapon = false, nil
		log("left weapon changed; no longer sheathed")
	end

	LI.zoneBump(cls)
	local mode = LI.mode(cls)
	local lt = readLT() or 0
	if lt >= LT_ON then
		ZZM_ltFist = true
	elseif lt < LT_OFF then
		ZZM_ltFist = false
	end
	local lb = ZZM_lbRaw
	if lb and not ZZM_lbWas then
		LI.press(pawn, lw, cls, mode)
	elseif not lb and ZZM_lbWas then
		LI.endPress(true)
	end
	ZZM_lbWas = lb

	-- The reach (GRAB_WINDOW): keeps trying to take hold, then it is a miss
	-- -- the hand opens and stays open until LB is pressed again.
	if ZZM_lbUse == "reach" then
		if ZZM_time >= ZZM_grabUntil then
			ZZM_lbUse = "miss"
		elseif ZZGrab ~= nil and ZZGrab.tryGrab(pawn, cls, true) then
			ZZM_lbUse = "grab"
		end
	end

	-- The hold can end with LB still down (grip slipped, body gone): an
	-- open hand until LB is pressed again.
	if ZZM_lbUse == "grab" and not (ZZGrab ~= nil and ZZGrab.isHolding()) then
		ZZM_lbUse = (mode == "empty") and "miss" or "done"
		ZZM_mArmed = false
	end

	ZZM_lbPass = ZZM_lbUse == "parry"
	LI.zoom(LI.LB_ZOOM and ZZM_lbUse == "parry")
	ZZMelee_LeftSwings = LI.leftSwings(mode)
	LI.swing(pawn, lw, cls, mode)
end

-- Whether a fast left hand is a weapon swing (whoosh, swing haptic): a
-- drawn weapon or the Power Fist always; a bare hand only as an LT fist.
-- Never while holding a stealer or reaching for one.
function LI.leftSwings(mode)
	if ZZGrab ~= nil and ZZGrab.isHolding() then return false end
	if mode ~= "empty" then return true end
	return (ZZM_lbUse == nil or ZZM_lbUse == "miss") and ZZM_ltFist
end

-- Whether LArm shows its closed pose. Bare hand ("#bare" key): reaching
-- for a grab, holding, gripping the sword behind the head, or an LT fist;
-- a missed grab is open (LB still held or not). Fist and claw: LT (the
-- charge) or a grab. A drawn mesh weapon poses the same frame for both, so
-- it is moot there.
function LI.handClosed(key)
	if ZZM_lbUse == "grab" then return true end
	if string.sub(key, -5) == "#bare" then
		if ZZM_lbUse == "reach" or ZZM_lbUse == "holster" then return true end
		return ZZM_ltFist
	end
	return ZZM_lit
end

-- The bare-hand pose table for a weapon's ARM_POSES entry: open idle, and
-- the weapon's own grip as the closed fist. Cached per entry.
LI.bareSpecs = {}
function LI.bareSpec(spec)
	local b = LI.bareSpecs[spec]
	if b == nil then
		b = { open = LI.BARE_OPEN, closed = spec.closed,
		      openTime = 0.0, closedTime = spec.closedTime or 0.0 }
		LI.bareSpecs[spec] = b
	end
	return b
end

-- HAND HOLD. The open pose has L_Hand somewhere else in LArm's frame than
-- the grip pose does, so UEVR's grip (tuned for the grip pose) would put the
-- open hand in the wrong place. Each frame, right after UEVR has placed LArm
-- (UObjectHook ticks attachments in the pre-calc of view 1, and LuaLoader
-- runs after UObjectHook, so this post-calc of view 1 comes later), LArm is
-- moved by X = H_open^-1 * H_grip in its own frame, which puts the hand bone
-- exactly where the grip pose has it: world(hand) = H_open * X * W = H_grip * W.
-- H_grip is measured while the grip pose is showing (always, with the weapon
-- drawn); H_open is read live, so the first frame of a switch -- before the
-- bones have moved -- gives X = identity, not a jump.
LI.frame     = 0
LI.gripHands = {}   -- [anim address] = L_Hand in LArm space, in that pose

-- The same transform with its scale set to 1. The hand socket's transform
-- carries bone scale that differs between the two poses; left in, X had a
-- scale, and composing it every frame shrank the arm (v1). Rigid
-- transforms make X a pure move-and-turn of the hand bone.
function LI.rigid(t)
	local loc, rot = {}, {}
	kmath:BreakTransform(t, loc, rot, {})
	return kmath:MakeTransform(loc.result, rot.result, kmath:MakeVector(1.0, 1.0, 1.0))
end

function LI.holdHand()
	LI.frame = LI.frame + 1
	local arm, grip, now = ZZM_poseArm, LI.gripAnim, LI.poseAnim
	if not LI.HOLD_HAND or kmath == nil or arm == nil or grip == nil or now == nil then return end
	if not valid(arm) or not valid(grip) or not valid(now) then return end
	local gaddr = grip:get_address()
	if now:get_address() == gaddr then
		-- Grip pose showing: (re)measure its hand once the bones have settled.
		if LI.frame - (LI.poseAt or 0) >= 3 then
			LI.gripHands[gaddr] = LI.rigid(arm:GetSocketTransform("L_Hand", 2))   -- RTS_Component
		end
		return
	end
	local ref = LI.gripHands[gaddr]
	if not ZZM_sheathed or ref == nil then return end
	if LI.hit == nil then
		LI.hit = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
	end
	local h = LI.rigid(arm:GetSocketTransform("L_Hand", 2))
	local x = kmath:ComposeTransforms(kmath:InvertTransform(h), ref)
	-- Location and rotation ONLY. UEVR re-sets those every frame but never
	-- scale, so writing a whole transform (as the first version did) let any
	-- scale in X compound frame after frame: the arm shrank to
	-- 0.27/0.06/0.13 and stayed that way after this was switched off.
	local loc, rot = {}, {}
	kmath:BreakTransform(kmath:ComposeTransforms(x, arm:K2_GetComponentToWorld()), loc, rot, {})
	arm:K2_SetWorldLocationAndRotation(loc.result, rot.result, false, LI.hit, true)
end

-- Whether a skinned mesh is linked to a master pose (copying another
-- mesh's bones): the MasterPoseComponent weak pointer's object index, read
-- from the property's own offset. Seen live 2026-09-30: both arms linked to
-- CharacterMesh0 -- the walk cycle in a "frozen" arm. See RightHand.lua.
function LI.masterLinked(arm)
	if LI.masterOff == nil then
		LI.masterOff = 0x760   -- USkinnedMeshComponent::MasterPoseComponent in this 4.14 build
		pcall(function()
			local p = api:find_uobject("Class /Script/Engine.SkinnedMeshComponent"):find_property("MasterPoseComponent")
			if p ~= nil then LI.masterOff = p:get_offset() end
		end)
	end
	local ok, idx = pcall(function() return arm:read_dword(LI.masterOff) end)
	if not ok or idx == nil then return false end
	if idx >= 0x80000000 then idx = idx - 0x100000000 end
	if idx > 0 and not LI.masterLogged then
		LI.masterLogged = true
		log("the left arm had been linked back to the body animation; unlinked")
	end
	return idx > 0
end

-- LArm must stay at scale 1 (RArm's, and its own before the shrink above).
-- Nothing else in the game or UEVR writes its scale back, so a bad scale
-- would otherwise survive script reloads until a restart.
-- ...and now RX.AIK.VIEW_SCALE, as are RArm (and with it the gun on its
-- RGun socket) and the left weapon's mesh. Checked on every poll: the game
-- rebuilds parts on equip.
function LI.fixArmScale(pawn, lw)
	if kmath == nil then return end
	local k = RX.AIK.VIEW_SCALE
	local parts = {}
	pcall(function() parts[#parts + 1] = { pawn.LArm, "left arm" } end)
	pcall(function() parts[#parts + 1] = { pawn.RArm, "right arm" } end)
	if lw ~= nil then pcall(function() parts[#parts + 1] = { lw.MeleeWeapon, "left weapon" } end) end
	for _, e in ipairs(parts) do
		local comp = e[1]
		if comp ~= nil then
			local ok, x, y, z = pcall(function() return vecXYZ(comp.RelativeScale3D) end)
			if ok and x ~= nil and (math.abs(x - k) > 0.001 or math.abs(y - k) > 0.001 or math.abs(z - k) > 0.001) then
				pcall(function() comp:SetRelativeScale3D(kmath:MakeVector(k, k, k)) end)
				log("%s scale was %.2f %.2f %.2f; set to %.2f", e[2], x, y, z, k)
				-- An arm piece hangs off its arm and inherited that change: have
				-- the solve set its own scale again.
				for _, P in pairs(RX.aik) do P.scale = nil end
			end
		end
	end
end

uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(
	function(device, view_index, world_to_meters, position, rotation, is_double)
		-- Both eyes and the head's yaw, for RX.wristEstimate. rotation is a
		-- vector over the view Rotator: .x pitch, .y yaw, .z roll.
		pcall(function()
			RX.eyes[view_index % 2] = { position.x, position.y, position.z }
			RX.eyeYaw = rotation.y
		end)
		if (view_index + 1) % 2 ~= 0 then return end   -- same view UObjectHook ticks on
		local ok, err = pcall(LI.holdHand)
		if not ok and not LI.holdErr then
			LI.holdErr = true
			log("hand hold failed: %s", tostring(err))
		end
		-- The sword's weight, after UEVR has placed it.
		ok, err = pcall(RX.heftView)
		if not ok and not RX.heftErr then
			RX.heftErr = true
			log("heft (view) failed: %s", tostring(err))
		end
		-- After UEVR and the hand hold have placed LArm: chest, then arm piece.
		ok, err = pcall(RX.aikView)
		if not ok and not RX.aikViewErr then
			RX.aikViewErr = true
			log("arm ik (view) failed: %s", tostring(err))
		end
	end)

local function tick(delta)
	if not ENABLED then return end
	if not resolveStatics() then return end
	ZZM_time = ZZM_time + delta

	local lw, pawn, cls = resolveLeftWeapon()
	RX.heftMesh = nil   -- set again below while the sword is drawn
	-- Before the grip: an LB press here can sheathe or draw the weapon.
	LI.tick(pawn, lw, cls or "")
	applyLeftHand(pawn, lw, cls or "")

	local poll = false
	ZZM_accum = ZZM_accum + delta
	if ZZM_accum >= POLL_INTERVAL then
		ZZM_accum = 0.0
		poll = true
	end

	if poll then
		applyCannedSwing(pawn)
		if pawn ~= nil then LI.fixArmScale(pawn, lw) end
		RX.safe("heft lerp", RX.heftLerp)
	end
	-- Before the lw check: the arm is on show with or without a left weapon.
	applyArmHide(pawn, poll)
	if pawn ~= nil then
		RX.safe("right arm pose", RX.rightPose, pawn, poll)
		RX.safe("rig probe", RX.probe, pawn, delta)
		RX.safe("body", RX.bodyTick, pawn, poll)
		RX.safe("reverse grip", RX.revTick, cls or "")
		RX.safe("stun", RX.stunTick)
	elseif RX.body ~= nil then
		RX.bodyRelease()
	end

	if lw == nil then
		RX.safe("arm ik", RX.aikTick, pawn, "", poll)            -- hides the arm piece
		RX.safe("impale", RX.impTick, pawn, nil, nil, "", delta)   -- drops a body still on the blade
		releaseSword()
		releaseArmGlow()
		releaseArmPose(pawn)
		return
	end

	local mesh = nil
	pcall(function() mesh = lw.MeleeWeapon end)
	if poll or not sameObject(lw, ZZM_traceWeapon) then
		applyHitShake(lw)
		bindSwingSound(lw)
		if mesh ~= nil then applyTraceSource(lw, mesh, pawn) end
		ZZM_traceWeapon = lw
	end

	if ZZM_sheathed then
		-- On the back: no flame, no light, no sound -- put out, NOT released:
		-- releasing destroys the light actor, which hung the game (see
		-- LI.douse). The game may show the mesh again (it owns its
		-- visibility), so re-hide on every poll.
		LI.douse()
		if poll and mesh ~= nil then pcall(function() mesh:SetVisibility(false, true) end) end
	elseif string.find(cls, "ForceSword", 1, true) then
		releaseArmGlow()
		tickSword(lw, mesh, delta, poll)
		if RX.HEFT.CLASSES[cls] then RX.heftMesh = mesh end
		-- After tickSword: updateIgnition has just refreshed ZZM_lit.
		RX.safe("fire gate", RX.burnGate, lw, cls)
	elseif ARM_GLOW[cls] ~= nil then
		releaseSword()
		tickArmGlow(lw, pawn, delta, ARM_GLOW[cls])
	else
		releaseSword()
		releaseArmGlow()
	end
	-- After the glow: tickArmGlow has just updated ZZM_lit from LT.
	applyArmPose(pawn, cls, poll)
	RX.safe("arm ik", RX.aikTick, pawn, cls, poll)   -- before the wrist: the piece turns the sweeps off
	RX.safe("wrist", RX.wristTick, pawn, cls, delta)
	applySwingSound(pawn, lw, cls)
	RX.safe("impale", RX.impTick, pawn, lw, mesh, cls, delta)
	RX.safe("pommel bash", RX.bashTick, pawn, lw, mesh, cls, delta)
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local ok, err = pcall(tick, delta)
	if not ok then
		log("tick error: %s", tostring(err))
	end
end)

log("ZZ_Melee loaded (left hand %s%s, LT %d/%d, light r=%.0f, brightness %.1f)",
	LEFT_HAND_ENABLED and "on" or "off", TUNE_LEFT_HAND and " TUNE" or "",
	LT_ON, LT_OFF, LIGHT_RADIUS, FIRE_BRIGHTNESS)

--[[
	NOTES -- the non-obvious bits.

	LEFT HAND. The Librarian's left-hand options split two ways. Force Sword,
	Force Axe and Storm Shield carry their own mesh in MeleeWeapon. Power
	Fist and Lightning Claw carry none: equipping them swaps pawn.LArm's mesh
	(SHTerminator.SKArmLPowerFist = SK_TL-PowerFist-01a; BP_Imperium_Mother
	keeps MIDPowerfist / MIDLightningClaw for the same arm), so the arm itself
	must ride the controller.

	UEVR also restores a saved attachment for the path LeftWeapon ->
	MeleeWeapon (uobjecthook/15426945207052222384_mc_state.json). That path is
	the same for every mesh weapon, which is why they all used to share the
	sword's grip. SWORD_GRIP holds that file's numbers, so for the sword both
	sources agree; for other weapons this script's per-tick write wins.

	MotionControllerState has setters only -- no getter for either offset --
	so a grip adjusted in UEVR's UI cannot be read back from Lua. Tuning goes
	through the JSON UEVR saves, hence the verbatim quat/loc format.

	set_rotation_offset (reshade/lua-api/lib/src/ScriptContext.cpp) takes a
	UEVR_Quaternionf, a Vector4f, or a Vector3 read as Euler radians and
	converted with glm::quat(glm::yawPitchRoll(-e.y, e.x, -e.z)). The C side
	copies the quaternion's x/y/z/w by name. So a quaternion from UEVR's JSON
	is passed as UEVR_Quaternionf and lands exactly. Do not route it through
	Euler unless the build refuses the type: the first version of this file
	inverted glm::quat(vec3) instead, which put the sword 152 degrees off its
	grip, and because UEVR keeps a state's rotation in memory, switching the
	script off did not undo it.

	CameraManager's own Power Fist hook reads pawn.LeftWeapon, which returns
	nothing usable, so it never attached the fist. It now also stands down
	when ZZMelee_OwnsLeftHand is set, so the two cannot fight if it is ever
	fixed.

	ARM WEAPONS. UEVR places an attached component at
	    controller + convert(adjusted_rotation * location_offset)
	(reshade/src/mods/UObjectHook.cpp), i.e. the offset runs along the
	component's OWN axes -- (left, down, forward) as ZZ_Torch measured. So the
	grip that puts a point P of the arm on the controller is -P expressed in
	LArm's frame. P = L_Hand came from PS_PowerFist_04, which the fist BP
	attaches to that socket. The arm copies CharacterMesh0's animated pose, so
	P moves a little with aim pitch and with any pose the body plays; the grip
	holds for the pose it was measured in.

	ARM POSE. LArm has no anim instance of its own; MasterPoseComponent makes
	it copy CharacterMesh0, which is why the walk cycle, aim offset and the
	flat game's charge pose all moved the fist inside the controller grip.
	SetMasterPoseComponent(nil) + AnimationSingleNode + a stopped
	PlayAnimation gives it a still pose instead. A_T_PowerFistLeftClose is a
	single-frame clenched fist; A_T_PowerFistLeftIdle-01a a 2 s idle; both
	non-additive and loaded with the anim BP. HAND_LOCK then re-derives the
	grip every frame from where L_Hand sits in the current pose, so the tuned
	grip survives the change of pose. Release restores AnimationBlueprint mode
	and the master pose -- the LArm component survives weapon swaps, so the
	plain arm would otherwise stay frozen in the fist pose.

	CANNED SWING. The attack montages (AM_T-ForceSword-Melee-L/R0x and the
	other weapons' sets in ABP-Terminator-01) are one pose track in slot
	"MeleeSlot" and carry no notifies; their sequences have none either. Hit
	timing is code-driven -- the trace ran with the BP's Attack flag never
	set. So the montage is purely what moves the arms: LArm and RArm copy
	CharacterMesh0's pose (MasterPoseComponent), and CharacterMesh0 is where
	the montage lands. Renaming the Slot node to None makes every slot
	lookup miss, so the node passes its source pose through. Measured in
	headset: arms stop swinging, hits still land.

	HIT SHAKE. CamShakeAndPowerfist opens with JumpIfNot
	OnHitStealerPlayCamShake to its end, so that one bool on the weapon is
	the whole melee hit shake. It is per weapon instance, so it is re-asserted
	on every weapon change and poll.

	WHAT THE SWORD'S "FIRE" IS. Three separate things on BP_ForceSword_C,
	all children of the MeleeWeapon skeletal mesh (SK_ForceSword-02b):
	  - material slot 1, MI_ForceSwordEffect_Inst1 -> M_WeaponForceEffect_MAT.
	    Unlit, additive. Emissive = RGB_Masks texture (T_ForceSword_Energy-
	    01a-1RGBa) through two panners (BorderFlow, DetailsFlow) x "Color".
	    Stock Color is a dim HDR orange, which is why it reads as weak.
	  - PS_ForceSwordParticles_01_P: GPU glow motes (M_GlowOrb) on a cylinder
	    around the blade, stirred by a vector field.
	  - ParticleSystem1 = PS_WEAP_Lightning-02a at socket "FX": GPU sprites
	    plus an AnimTrail emitter (M_AnimTrail).

	WHY VISIBILITY, NOT DEACTIVATE, FOR THE PARTICLES. The BP drives
	activation itself (BeginTrails/EndTrails, NotifyNemesis). Hiding leaves
	its state machine untouched; the GPU simulation keeps running, which is
	negligible for two small emitters and means re-ignition is instant.

	WHY THE LIGHT IS PARENTED TO MeleeWeapon, NOT THE ACTOR. The actor root
	(Scene1) stays on CharacterMesh0 at the animated hand. Only the MeleeWeapon
	component rides the left controller. Anything parented to the actor
	would light up where the invisible body's hand is.

	LIGHT COST. Dynamic point light cost is screen area, so ~radius^2, paid
	twice in VR. 600 cm without shadows is cheap; the storm bolter's muzzle
	lights were 3000. Shadows would make the blade and arm shadow-cast onto
	themselves from inside the light, and cost a cube shadow map per eye.

	HIT DETECTION -- SkeletalMeshValid. While BP_MeleeWeaponMother's Attack
	window is open (anim notifies), it sweeps a box from OldLoc to
	AttackTraceEnd every tick. DefineTraceDependingWeapon picks the end point
	(decoded from its bytecode):
	    SkeletalMeshValid  -> MeleeWeapon socket SocketEndTraceLine (BladeTop)
	                          + 26 cm (TraceLineRadius) along the socket's X
	    otherwise          -> K2_GetActorLocation + 50 cm * GetActorRightVector
	and OrientationBoxTrace aligns the (150,10,10) half-extent box to the same
	socket, or to the actor, by the same flag. The ubergraph sets the flag
	once, as MeleeWeapon.SkeletalMesh != None, before the skin component has
	assigned the mesh -- so it ships stuck at false and every swing is traced
	from the actor root, which rides the invisible body's hand on
	CharacterMesh0. Flipping it routes the stock sweep through the visible
	weapon; damage, dismemberment and FX are untouched because the rest of
	the pipeline only consumes the resulting hits. Arm weapons have no mesh,
	so their false is genuine and they still trace from the animated hand.

	The flag alone was measured NOT to be enough: mid-swing AttackTraceEnd
	sat 2-2.6 m from the visible tip. UEVR's UObjectHook writes the mesh's
	RELATIVE transform, so with MeleeWeapon still under Scene1 (on the
	animated hand) the attack animation moves it during the tick and UEVR
	only corrects it afterwards. Setting bAbsoluteLocation/Rotation instead
	was tried and throws the blade to the world origin (UEVR's relative
	numbers become world numbers) -- do not. Re-parenting to the capsule
	keeps UEVR's relative write meaningful and takes the animation out.

	SOCKETS on SK_ForceSword-01a_Skeleton (component space, cm):
	  BladeBase (15, 27, -11)   BladeCenter (24, 73, -21)   BladeTop (38, 155, -38)
	  FX (6, 33, -13) on Bone001. Blade is ~133 cm.

	LEFT INPUT, MOVED FROM MAINHANDLER. In the game's input map gamepad LB is
	"Parrying" (so is LeftControl) and the right mouse button is
	"WeaponZoom". MainHandler let LB through untouched and also held the
	right mouse while LB was down; this file keeps both for a parry, but
	decides on each press whether it IS a parry -- which needs LB held back
	from the game until the tick has looked at the hand. MainHandler's LT
	zeroing, swing machine and LB->mouse block each check
	ZZMelee_OwnsLeftInput, so LI.ENABLED = false restores them exactly.

	FIRE ON KILL. Measured 2026-09-30: the sword instance's DMGTypes header
	(SHMeleeWeapon + 0x408) is {data, Num 3, Max 16} holding 04 0F 02; its
	CDO is the same, and DynamicallyAddedDMGTypes is empty. The donor,
	Default__MaterialExpressionComment.Text (+0x68), is {0, 0, 0} -- unused.
	Nothing in SHStealer's BP calls MakePawnBurn or the burn condition, so
	the burn is native and keyed on the list; the list is the only lever.
	If the fire still shows on light kills after the log says "Burn follows
	LT", the burn is coming from something else and BURN_GATE should go off.

	IMPALE. Judged on the blade's own motion (BladeBase / BladeTop sockets),
	not the controller's, so it holds for any grip: the hilt end moving
	along the blade, point first, is a thrust; a slash moves it across, a
	wrist flick moves the tip. The body is ZZ_Grab's: ZZGrab.impale kills
	it and puts it on the left hand's hold with ZZG_point.L set to the
	pierce point, so updateCorpse, trackHand's velocity history and
	releaseCorpse's fling all run on the blade unchanged. ZZGrab.isHolding
	is true meanwhile, which is what stops LI's swings firing the game's
	attack; the arm trim's "holding" layer excludes impales (the hand is
	not holding it, the blade is).

	RIGHT ARM. Frozen like LArm (see ARM POSE). Its recoil and reload
	animations no longer show on the arm or the gun either. CameraManager
	switches to RARM_FROZEN_GRIP while ZZMelee_RightArmFrozen is set.

	ARM IK / BODY. Measured live 2026-10-02: Torso, both pauldrons and Head
	are all MasterPoseComponent-linked to CharacterMesh0 (same bone positions
	in their own frames to the hundredth of a cm), so the chest shows the
	hips' animated pose and its bForceRefpose does nothing. CameraManager hung
	the pauldrons on the headset with zero offset; their meshes are built
	around the feet, so their shoulder bones sat ~190 cm above the eyes. On
	the chest's transform they land exactly on it. The piece is a whole
	SkeletalMeshActor because 4.14 cannot add a component (see the light);
	MeshComponentUpdateFlag 0 makes it refresh bones while hidden, which the
	self-test needs. bake_elbow.py bends BOTH elbows in L03, so the right
	piece plays the same sequence as the left. The right arm's hand is final
	only after RightHand.lua's pin, which runs in its own view callback --
	before this file's, scripts loading (and registering) alphabetically.

	SHEATHED. The game still has the weapon equipped; only the mesh is
	hidden. Hence the swing never fires the game's attack while sheathed (it
	would swing an invisible sword with full damage) and LB never reaches
	the game as a parry. The weapon's UEVR attachment is left alone so it
	comes back in the right grip, and LArm keeps the weapon's armGrip and
	pose, so the bare hand sits exactly where the drawn hand does. Nothing
	is destroyed on sheathing -- see LI.douse for the hang that caused.
]]
