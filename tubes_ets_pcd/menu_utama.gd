# menu_utama.gd
extends Control

@onready var start_button: Button = $VBoxContainer/StartButton
@onready var credits_button: Button = $VBoxContainer/CreditsButton
@onready var settings_button: Button = $VBoxContainer/SettingsButton
@onready var quit_button: Button = $VBoxContainer/QuitButton
@onready var version_label: Label = $VersionLabel

func _ready():
	# Connect button signals
	start_button.pressed.connect(_on_start_button_pressed)
	credits_button.pressed.connect(_on_credits_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	
	# Set version info
	version_label.text = "Version 1.0 - UDP Webcam Client"
	
	print("🎮 Main menu loaded")

func _on_start_button_pressed():
	print("🚀 Starting webcam client...")
	# Load webcam client scene
	get_tree().change_scene_to_file("res://webcam_client_udp.tscn")

func _on_credits_button_pressed():
	print("📝 Showing credits...")
	# Bisa ditambahkan scene credits nanti
	OS.alert("UDP Webcam Client with Blush Effect\n\nDeveloped by Your Name\nUsing Godot 4.2", "Credits")

func _on_settings_button_pressed():
	print("⚙️ Opening settings...")
	# Bisa ditambahkan scene settings nanti
	OS.alert("Settings menu coming soon!", "Settings")

func _on_quit_button_pressed():
	print("👋 Quitting application...")
	get_tree().quit()
