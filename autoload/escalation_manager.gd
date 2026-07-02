extends Node
## EscalationManager - Escalation Curve (Section 7) + Cross-System Interactions (Section 8.5)
## Manages the overall game progression from mundane to horror, coordinating all systems.

signal escalation_phase_changed(old_phase: String, new_phase: String)
signal horror_event_triggered(event_type: String, severity: int)

enum GamePhase {
	EARLY,   # Shifts 1-3: Almost entirely mundane
	MID,     # Shifts 4-6: Genuinely ambiguous cases appear
	LATE     # Shifts 7+: Tool breaks, impossible things, unreliable HQ
}

var current_phase: GamePhase = GamePhase.EARLY
var current_shift: int = 0

# Configuration for escalation timing
var early_game_max_shifts: int = 3
var mid_game_max_shifts: int = 6

# Horror event tracking
var triggered_horror_events: Dictionary = {}  # event_id -> triggered bool
var zone_bleed_active_zones: Array[String] = []
var phantom_camera_count: int = 0
var retroactive_dread_events: int = 0
var self_sighting_events: int = 0

func _ready() -> void:
	# Connect to GameManager for shift tracking
	if GameManager:
		GameManager.shift_started.connect(_on_shift_started)
		GameManager.shift_ended.connect(_on_shift_ended)

func _on_shift_started(shift_number: int) -> void:
	current_shift = shift_number
	update_game_phase()
	_try_trigger_phase_events()

func _on_shift_ended(_success: bool) -> void:
	# End-of-shift processing, if needed
	pass

func update_game_phase() -> void:
	"""Updates the current game phase based on shift number."""
	var old_phase = GamePhase.keys()[current_phase]
	var new_phase: GamePhase
	
	if current_shift <= early_game_max_shifts:
		new_phase = GamePhase.EARLY
	elif current_shift <= mid_game_max_shifts:
		new_phase = GamePhase.MID
	else:
		new_phase = GamePhase.LATE
	
	if new_phase != current_phase:
		current_phase = new_phase
		escalation_phase_changed.emit(old_phase, GamePhase.keys()[new_phase])
		
		# Update dependent systems
		_update_system_phases()

func _update_system_phases() -> void:
	"""Updates all dependent systems when game phase changes."""
	var phase_name = GamePhase.keys()[current_phase]
	
	# Update CredibilityManager's HQ reliability
	CredibilityManager.set_hq_reliability_by_game_phase(phase_name)
	
	# Adjust zone risk tiers based on phase
	_adjust_zone_risk_tiers()

func _adjust_zone_risk_tiers() -> void:
	"""Adjusts zone risk tiers based on current game phase."""
	match current_phase:
		GamePhase.EARLY:
			# Keep most zones at low risk
			_set_all_zone_tiers(0, 1)
		GamePhase.MID:
			# Start escalating some zones
			_escalate_random_zones(1, 2)
		GamePhase.LATE:
			# Multiple zones at high risk
			_escalate_random_zones(3, 5)

func _set_all_zone_tiers(min_tier: int, max_tier: int) -> void:
	"""Sets all zones to a specific risk tier range."""
	if not ZoneManager:
		return
	
	for zone_id in ZoneManager.get_all_zones():
		var tier = randi_range(min_tier, max_tier)
		ZoneManager.update_zone_risk_tier(zone_id, tier)

func _escalate_random_zones(min_tier: int, max_tier: int) -> void:
	"""Escalates a random subset of zones."""
	if not ZoneManager:
		return
	
	var all_zones = ZoneManager.get_all_zones()
	var zones_to_escalate = randi_range(1, max(1, all_zones.size() / 2))

	for i in range(zones_to_escalate):
		if all_zones.is_empty():
			break
		var idx = randi_range(0, all_zones.size() - 1)
		var zone_id = all_zones[idx]
		ZoneManager.update_zone_risk_tier(zone_id, randi_range(min_tier, max_tier))
		all_zones.remove_at(idx)

func trigger_census_mismatch(zone_id: String) -> bool:
	"""
	Triggers a census mismatch event (Section 8.1).
	Returns true if successfully triggered.
	"""
	var event_id = "census_%s_%d" % [zone_id, current_shift]
	if triggered_horror_events.has(event_id) and triggered_horror_events[event_id]:
		return false  # Already triggered this shift

	var profile = ZoneManager.get_zone(zone_id)
	if not profile:
		return false

	# Determine if this should be "over" or "under" count
	var expected = profile.expected_npc_count
	var actual: int
	var is_over: bool

	if randf() < 0.5:
		# Under count - missing entity
		actual = max(0, expected - 1)
		is_over = false
	else:
		# Over count - extra entity
		actual = expected + 1
		is_over = true

	# Check for mismatch (this will emit the signal)
	var mismatch_detected = ZoneManager.check_census_mismatch(zone_id, actual)

	if mismatch_detected:
		triggered_horror_events[event_id] = true
		
		# Create anomaly report
		var anomaly_type = HQReportSystem.AnomalyType.COUNT_WRONG
		var description = "Entity count discrepancy in %s: expected %d, observed %d" % [
			profile.zone_name, expected, actual
		]
		HQReportSystem.create_anomaly_report("", zone_id, anomaly_type, description)
		
		horror_event_triggered.emit("census_mismatch", 1 if is_over else -1)

	return mismatch_detected

func trigger_retroactive_dread(camera_id: String, clip_id: String) -> bool:
	"""
	Triggers a retroactive dread event (Section 8.2).
	Adds an anomaly to archived footage that wasn't visible live.
	"""
	var event_id = "retro_%s_%d" % [camera_id, current_shift]
	if triggered_horror_events.has(event_id) and triggered_horror_events[event_id]:
		return false

	if not FootageArchive:
		return false

	# Only trigger in mid/late game
	if current_phase == GamePhase.EARLY:
		return false

	var anomaly_types = [
		"shadow_figure",
		"extra_person",
		"missing_person",
		"object_teleport",
		"time_skip"
	]
	var selected_type = anomaly_types[randi_range(0, anomaly_types.size() - 1)]
	var frame_position = randf_range(0.2, 0.8)  # Not at the very start or end

	FootageArchive.add_retroactive_anomaly(
		clip_id,
		selected_type,
		"Archived footage shows %s not visible in live feed" % selected_type,
		frame_position
	)

	triggered_horror_events[event_id] = true
	retroactive_dread_events += 1

	horror_event_triggered.emit("retroactive_dread", 2)
	return true

func trigger_self_sighting(camera_id: String) -> bool:
	"""
	Triggers a self-sighting event (Section 8.3).
	Player's silhouette appears on camera they're nowhere near.
	"""
	var event_id = "self_sight_%s_%d" % [camera_id, current_shift]
	if triggered_horror_events.has(event_id) and triggered_horror_events[event_id]:
		return false

	if not CameraSystem:
		return false

	# Only trigger in late game
	if current_phase != GamePhase.LATE:
		return false

	# Verify player is NOT near this camera
	var camera_profile = CameraSystem.get_camera(camera_id)
	if not camera_profile:
		return false

	if CameraSystem.is_player_near_camera(camera_id, 15.0):
		return false  # Player is too close, wouldn't be a "sighting"

	# Set phantom state
	CameraSystem.set_phantom_state(camera_id, "self_sighting")

	triggered_horror_events[event_id] = true
	self_sighting_events += 1
	phantom_camera_count += 1

	horror_event_triggered.emit("self_sighting", 3)

	# Create report for this
	HQReportSystem.create_anomaly_report(
		camera_id,
		camera_profile.home_zone,
		HQReportSystem.AnomalyType.PHANTOM_CONTENT,
		"Player silhouette detected on camera %s despite player being elsewhere" % camera_id
	)

	return true

func trigger_zone_bleed(zone_id: String, intensity: float) -> bool:
	"""
	Triggers zone bleed effect (Section 8.4).
	Applies gradual drift to zone baseline.
	"""
	var event_id = "bleed_%s_%d" % [zone_id, current_shift]
	if triggered_horror_events.has(event_id) and triggered_horror_events[event_id]:
		return false

	if not ZoneManager:
		return false

	# Apply sound and lighting drift
	var sound_delta = intensity * 0.15
	var lighting_delta = intensity * 0.1

	ZoneManager.apply_zone_bleed(zone_id, sound_delta, lighting_delta)

	if not zone_bleed_active_zones.has(zone_id):
		zone_bleed_active_zones.append(zone_id)

	triggered_horror_events[event_id] = true

	horror_event_triggered.emit("zone_bleed", int(intensity * 10))
	return true

func get_horror_intensity() -> float:
	"""Returns overall horror intensity based on triggered events."""
	var intensity = 0.0

	# Retroactive dread contributes
	intensity += retroactive_dread_events * 0.1

	# Self-sightings contribute heavily
	intensity += self_sighting_events * 0.3

	# Zone bleed contributes per zone
	intensity += zone_bleed_active_zones.size() * 0.15

	# Phantom cameras contribute
	intensity += phantom_camera_count * 0.2

	return clamp(intensity, 0.0, 1.0)

func can_trigger_horror_event(event_type: String) -> bool:
	"""Checks if a horror event type can be triggered in current phase."""
	match event_type:
		"census_mismatch":
			return current_phase != GamePhase.EARLY  # Mid or late only
		"retroactive_dread":
			return current_phase != GamePhase.EARLY
		"self_sighting":
			return current_phase == GamePhase.LATE
		"zone_bleed":
			return current_phase != GamePhase.EARLY
		_:
			return true

func _try_trigger_phase_events() -> void:
	"""Auto-triggers contextual horror events based on current phase for demo/progression."""
	if not ZoneManager or not HQReportSystem:
		return

	var all_zones = ZoneManager.get_all_zones()
	if all_zones.is_empty():
		return

	var rand_zone = all_zones[randi() % all_zones.size()]

	match current_phase:
		GamePhase.EARLY:
			# Almost no horror, maybe very rare mundane bleed hint
			if randf() < 0.1:
				trigger_zone_bleed(rand_zone, 0.1)
		GamePhase.MID:
			# Ambiguous: census mismatch or light zone bleed
			if randf() < 0.4:
				trigger_census_mismatch(rand_zone)
			elif randf() < 0.3:
				trigger_zone_bleed(rand_zone, 0.25)
		GamePhase.LATE:
			# High chance of multiple layered horrors
			if randf() < 0.6:
				trigger_census_mismatch(rand_zone)
			if randf() < 0.4:
				trigger_zone_bleed(rand_zone, 0.4)
			# Self sighting on a random camera in late game (if player pos set)
			var cams = CameraSystem.get_all_cameras()
			if not cams.is_empty() and randf() < 0.3:
				var rand_cam = cams[randi() % cams.size()]
				trigger_self_sighting(rand_cam)