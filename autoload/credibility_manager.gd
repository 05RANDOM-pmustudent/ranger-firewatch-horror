extends Node
## CredibilityManager - Trust Economy System (Section 5)
## Manages the player's credibility with HQ and the consequences of reporting behavior.

signal credibility_changed(new_value: float, old_value: float)
signal credibility_threshold_crossed(threshold_name: String, crossed_above: bool)
signal hq_response_type_changed(new_response_type: String)

enum ReportOutcome {
	FALSE_ALARM,   # Player reported something that wasn't an anomaly
	MUNDANE,       # Player reported a real but explainable event (weather, wildlife)
	GENUINE        # Player reported a genuine anomaly/horror event
}

enum HQReliability {
	RELIABLE,      # Early game: HQ gives clear, accurate responses
	AMBIGUOUS,     # Mid game: HQ responses become less clear
	UNRELIABLE     # Late game: HQ contradicts itself or knows things prematurely
}

# Credibility thresholds (0.0 to 100.0)
const CRITICAL_LOW_THRESHOLD: float = 20.0
const LOW_THRESHOLD: float = 40.0
const HIGH_THRESHOLD: float = 75.0
const CRITICAL_HIGH_THRESHOLD: float = 90.0

var current_credibility: float = 50.0  # Start at neutral
var total_reports_made: int = 0
var false_alarms: int = 0
var mundane_reports: int = 0
var genuine_reports: int = 0
var hq_reliability: HQReliability = HQReliability.RELIABLE

# Response timer configuration
var response_timer_active: bool = false
var response_time_remaining: float = 0.0
var pending_report_id: String = ""

func _ready() -> void:
	pass

func submit_report(report_id: String, report_type: String) -> void:
	"""Called when player submits a report to HQ."""
	total_reports_made += 1
	pending_report_id = report_id
	response_timer_active = true
	response_time_remaining = get_response_timer_duration()

func resolve_report(outcome: ReportOutcome) -> void:
	"""Resolves a pending report and adjusts credibility accordingly."""
	match outcome:
		ReportOutcome.FALSE_ALARM:
			false_alarms += 1
			adjust_credibility(-15.0)  # Heavy penalty for false alarms
		ReportOutcome.MUNDANE:
			mundane_reports += 1
			adjust_credibility(-5.0)   # Small penalty for mundane reports (wastes HQ time)
		ReportOutcome.GENUINE:
			genuine_reports += 1
			adjust_credibility(10.0)   # Reward for catching real anomalies
	
	response_timer_active = false
	pending_report_id = ""

func adjust_credibility(amount: float) -> void:
	"""Adjusts credibility by the given amount and emits signals if thresholds are crossed."""
	var old_value = current_credibility
	current_credibility = clamp(current_credibility + amount, 0.0, 100.0)
	
	if not is_equal_approx(old_value, current_credibility):
		credibility_changed.emit(current_credibility, old_value)
		check_threshold_crossings(old_value, current_credibility)
		
		# Update HQ response type based on credibility
		update_hq_response_type()

func check_threshold_crossings(old_value: float, new_value: float) -> void:
	"""Checks if any credibility thresholds were crossed."""
	var thresholds = [
		["critical_low", CRITICAL_LOW_THRESHOLD],
		["low", LOW_THRESHOLD],
		["high", HIGH_THRESHOLD],
		["critical_high", CRITICAL_HIGH_THRESHOLD]
	]
	
	for threshold_data in thresholds:
		var threshold_name = threshold_data[0]
		var threshold_value = threshold_data[1]
		
		var was_below = old_value < threshold_value
		var is_below = new_value < threshold_value
		
		if was_below != is_below:
			var crossed_above = not is_below
			credibility_threshold_crossed.emit(threshold_name, crossed_above)

func update_hq_response_type() -> void:
	"""Updates how HQ responds based on current credibility level."""
	var new_response_type: String
	if current_credibility >= CRITICAL_HIGH_THRESHOLD:
		new_response_type = "trusting"    # HQ trusts player judgment
	elif current_credibility >= HIGH_THRESHOLD:
		new_response_type = "professional" # Standard professional response
	elif current_credibility >= LOW_THRESHOLD:
		new_response_type = "skeptical"    # HQ questions player reports
	else:
		new_response_type = "dismissive"   # HQ may ignore or reject reports
	
	hq_response_type_changed.emit(new_response_type)

func get_response_timer_duration() -> float:
	"""Returns the response timer duration based on current credibility."""
	# Lower credibility = longer wait times from HQ
	if current_credibility >= HIGH_THRESHOLD:
		return 30.0   # Fast response when trusted
	elif current_credibility >= LOW_THRESHOLD:
		return 60.0   # Standard response time
	else:
		return 120.0  # Long delays when credibility is low

func can_escalate_to_hq() -> bool:
	"""Returns whether the player can currently escalate to HQ."""
	# Cannot escalate if credibility is critically low
	return current_credibility > CRITICAL_LOW_THRESHOLD

func get_credibility_description() -> String:
	"""Returns a human-readable description of current credibility status."""
	if current_credibility >= CRITICAL_HIGH_THRESHOLD:
		return "HQ fully trusts your judgment"
	elif current_credibility >= HIGH_THRESHOLD:
		return "HQ respects your reports"
	elif current_credibility >= LOW_THRESHOLD:
		return "HQ is skeptical of your reports"
	else:
		return "HQ dismisses most of your reports"

func set_hq_reliability_by_game_phase(shift_category: String) -> void:
	"""Sets HQ reliability based on game phase (called by GameManager)."""
	match shift_category:
		"early":
			hq_reliability = HQReliability.RELIABLE
		"mid":
			hq_reliability = HQReliability.AMBIGUOUS
		"late":
			hq_reliability = HQReliability.UNRELIABLE

func _process(delta: float) -> void:
	if response_timer_active:
		response_time_remaining -= delta
		if response_time_remaining <= 0:
			# Timer expired - this could trigger negative consequences
			response_timer_active = false
			pending_report_id = ""
			# Optionally penalize for taking too long to follow up
			adjust_credibility(-5.0)
