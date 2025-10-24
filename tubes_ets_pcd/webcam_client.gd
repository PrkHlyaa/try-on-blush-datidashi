extends Control

@onready var texture_rect: TextureRect = $VideoContainer/TextureRect
@onready var status_label: Label = $StatusLabel
@onready var connect_button: Button = $ControlPanel/ConnectButton
@onready var quit_button: Button = $ControlPanel/QuitButton
@onready var no_signal_label: Label = $VideoContainer/NoSignalLabel
@onready var fps_label: Label = $InfoPanel/FPSLabel
@onready var resolution_label: Label = $InfoPanel/ResolutionLabel
@onready var data_rate_label: Label = $InfoPanel/DataRateLabel

var tcp_client: StreamPeerTCP
var is_connected: bool = false
var server_host: String = "127.0.0.1"
var server_port: int = 8888
var buffer: PackedByteArray = PackedByteArray()

# Performance monitoring
var frame_count: int = 0
var last_fps_time: float = 0.0
var current_fps: float = 0.0
var bytes_received: int = 0
var last_data_rate_time: float = 0.0
var current_data_rate: float = 0.0

func _ready():
	# Inisialisasi TCP client
	tcp_client = StreamPeerTCP.new()
	
	# Connect button signals
	connect_button.pressed.connect(_on_connect_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	
	# Update status
	update_status("Ready to connect")
	update_info_display()
	
	# Show no signal initially
	no_signal_label.visible = true
	
	# Debug info
	print("Godot client initialized")
	print("Attempting to connect to: ", server_host, ":", server_port)

func _on_quit_button_pressed():
	get_tree().quit()

func _process(delta):
	if is_connected and tcp_client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		receive_frame()
		update_performance_metrics(delta)
	elif is_connected and tcp_client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		# Koneksi terputus
		disconnect_from_server()

func _on_connect_button_pressed():
	if is_connected:
		disconnect_from_server()
	else:
		# Pastikan tidak ada koneksi sebelumnya
		if tcp_client.get_status() != StreamPeerTCP.STATUS_NONE:
			tcp_client.disconnect_from_host()
			await get_tree().process_frame
		
		connect_to_server()

func connect_to_server():
	if is_connected:
		print("Already connected!")
		return
		
	print("Starting connection attempt...")
	update_status("Connecting...")
	
	# Reset TCP client jika perlu
	if tcp_client.get_status() != StreamPeerTCP.STATUS_NONE:
		print("Resetting TCP client...")
		tcp_client.disconnect_from_host()
		await get_tree().create_timer(0.1).timeout  # Wait 100ms
	
	var error = tcp_client.connect_to_host(server_host, server_port)
	print("Connect attempt result: ", error)
	
	if error != OK:
		update_status("Failed to connect - Error: " + str(error))
		print("Connection failed with error: ", error)
		return
	
	# Tunggu koneksi dengan timeout
	var timeout = 0
	var max_timeout = 180  # 3 detik pada 60fps (lebih pendek)
	
	print("Waiting for connection...")
	while tcp_client.get_status() == StreamPeerTCP.STATUS_CONNECTING and timeout < max_timeout:
		await get_tree().process_frame
		timeout += 1
		if timeout % 60 == 0:  # Print every second
			print("Still connecting... ", timeout/60, "s")
	
	var final_status = tcp_client.get_status()
	print("Final connection status: ", final_status)
	
	if final_status == StreamPeerTCP.STATUS_CONNECTED:
		is_connected = true
		update_status("Connected - Waiting for video...")
		connect_button.text = "Disconnect"
		print("✅ Connected! Waiting for video data...")
		
		# Kirim sinyal ready ke server (opsional)
		tcp_client.put_data("READY".to_utf8_buffer())
	else:
		update_status("Connection failed - Status: " + str(final_status))
		print("❌ Connection failed with status: ", final_status)
		tcp_client.disconnect_from_host()

func disconnect_from_server():
	is_connected = false
	tcp_client.disconnect_from_host()
	buffer.clear()
	update_status("Disconnected")
	connect_button.text = "Connect to Server"
	
	# Clear texture and show no signal
	texture_rect.texture = null
	no_signal_label.visible = true
	
	# Reset performance metrics
	frame_count = 0
	bytes_received = 0
	current_fps = 0.0
	current_data_rate = 0.0
	update_info_display()

func receive_frame():
	var available_bytes = tcp_client.get_available_bytes()
	if available_bytes > 0:
		print("Receiving ", available_bytes, " bytes")
		var new_data = tcp_client.get_data(available_bytes)
		
		if new_data[0] == OK:
			buffer.append_array(new_data[1])
			bytes_received += new_data[1].size()
			process_buffer()
		else:
			print("Error receiving data: ", new_data[0])

func process_buffer():
	while buffer.size() >= 4:  # Minimal butuh 4 bytes untuk header
		# Baca ukuran frame dari 4 bytes pertama
		var frame_size = bytes_to_int(buffer.slice(0, 4))
		
		if frame_size <= 0 or frame_size > 1048576:  # Max 1MB per frame
			print("Invalid frame size: ", frame_size)
			buffer.clear()
			return
		
		# Cek apakah kita sudah punya data lengkap
		if buffer.size() >= frame_size + 4:
			# Ambil data frame (skip 4 bytes header)
			var frame_data = buffer.slice(4, frame_size + 4)
			
			# Hapus data yang sudah diproses dari buffer
			buffer = buffer.slice(frame_size + 4)
			
			# Proses frame
			display_frame(frame_data)
		else:
			# Data belum lengkap, tunggu data selanjutnya
			break

func bytes_to_int(bytes: PackedByteArray) -> int:
	# Convert 4 bytes ke integer (big-endian)
	if bytes.size() != 4:
		return 0
	
	return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]

func display_frame(frame_data: PackedByteArray):
	# Buat Image dari data JPEG
	var image = Image.new()
	var error = image.load_jpg_from_buffer(frame_data)
	
	if error == OK:
		# Buat ImageTexture dari Image
		var texture = ImageTexture.new()
		texture.set_image(image)
		
		# Tampilkan di TextureRect
		texture_rect.texture = texture
		no_signal_label.visible = false
		
		# Update resolution info
		resolution_label.text = "Resolution: %dx%d" % [image.get_width(), image.get_height()]
		
		# Update frame count
		frame_count += 1
	else:
		print("Error loading image: ", error)

func update_performance_metrics(delta: float):
	# Update FPS calculation
	last_fps_time += delta
	if last_fps_time >= 1.0:
		current_fps = frame_count / last_fps_time
		frame_count = 0
		last_fps_time = 0.0
	
	# Update data rate calculation
	last_data_rate_time += delta
	if last_data_rate_time >= 1.0:
		current_data_rate = bytes_received / last_data_rate_time / 1024.0  # KB/s
		bytes_received = 0
		last_data_rate_time = 0.0
		
	update_info_display()

func update_info_display():
	if is_connected:
		fps_label.text = "FPS: %.1f" % current_fps
		data_rate_label.text = "Data Rate: %.1f KB/s" % current_data_rate
	else:
		fps_label.text = "FPS: --"
		resolution_label.text = "Resolution: --"
		data_rate_label.text = "Data Rate: --"

func update_status(message: String):
	status_label.text = "Status: " + message
	print("Webcam Client: " + message)

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if is_connected:
			disconnect_from_server()
		get_tree().quit()
