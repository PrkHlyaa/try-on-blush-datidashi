extends Control

@onready var texture_rect: TextureRect = $VideoContainer/TextureRect
@onready var status_label: Label = $StatusLabel
@onready var connect_button: Button = $ControlPanel/ConnectButton
@onready var quit_button: Button = $ControlPanel/QuitButton
@onready var no_signal_label: Label = $VideoContainer/NoSignalLabel
@onready var fps_label: Label = $InfoPanel/FPSLabel
@onready var resolution_label: Label = $InfoPanel/ResolutionLabel
@onready var data_rate_label: Label = $InfoPanel/DataRateLabel

var udp_client: PacketPeerUDP
var is_connected: bool = false
var server_host: String = "127.0.0.1"
var server_port: int = 8888

# Frame reassembly
var frame_buffers: Dictionary = {}  # seq_num -> {total_packets, received_packets, data_parts}
var last_completed_sequence: int = 0
var frame_timeout: float = 1.0  # 1 detik timeout untuk frame

# Performance monitoring
var frame_count: int = 0
var last_fps_time: float = 0.0
var current_fps: float = 0.0
var bytes_received: int = 0
var last_data_rate_time: float = 0.0
var current_data_rate: float = 0.0

# Packet statistics
var packets_received: int = 0
var frames_completed: int = 0
var frames_dropped: int = 0

func _ready():
	# Inisialisasi UDP client
	udp_client = PacketPeerUDP.new()
	
	# Connect button signals
	connect_button.pressed.connect(_on_connect_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	
	# Update status
	update_status("Ready to connect")
	update_info_display()
	
	# Show no signal initially
	no_signal_label.visible = true
	
	# Debug info
	print("🎮 Godot UDP client initialized")
	print("Target server: ", server_host, ":", server_port)

func _on_quit_button_pressed():
	get_tree().quit()

func _process(delta):
	if is_connected:
		receive_packets()
		cleanup_old_frames()
		update_performance_metrics(delta)

func _on_connect_button_pressed():
	if is_connected:
		disconnect_from_server()
	else:
		connect_to_server()

func connect_to_server():
	if is_connected:
		print("⚠️  Already connected!")
		return
		
	print("🔄 Starting UDP connection...")
	update_status("Connecting...")
	
	# Setup UDP connection
	var error = udp_client.connect_to_host(server_host, server_port)
	
	if error != OK:
		update_status("Failed to setup UDP - Error: " + str(error))
		print("❌ UDP setup failed: ", error)
		return
	
	# Kirim registrasi ke server
	var registration_message = "REGISTER".to_utf8_buffer()
	var send_result = udp_client.put_packet(registration_message)
	
	if send_result != OK:
		update_status("Failed to register - Error: " + str(send_result))
		print("❌ Registration failed: ", send_result)
		return
	
	print("📤 Registration sent, waiting for confirmation...")
	
	# Tunggu konfirmasi dari server
	var timeout = 0
	var max_timeout = 180  # 3 detik pada 60fps
	var confirmed = false
	
	while timeout < max_timeout and not confirmed:
		await get_tree().process_frame
		timeout += 1
		
		if udp_client.get_available_packet_count() > 0:
			var packet = udp_client.get_packet()
			var message = packet.get_string_from_utf8()
			
			if message == "REGISTERED":
				confirmed = true
				print("✅ Registration confirmed!")
			elif message == "SERVER_SHUTDOWN":
				update_status("Server is shutting down")
				return
	
	if confirmed:
		is_connected = true
		update_status("Connected - Receiving video...")
		connect_button.text = "Disconnect"
		print("🎥 Ready to receive video streams!")
		
		# Reset statistics
		packets_received = 0
		frames_completed = 0
		frames_dropped = 0
		frame_buffers.clear()
	else:
		update_status("Registration timeout")
		print("❌ Registration timeout")
		udp_client.close()

func disconnect_from_server():
	print("🔌 Disconnecting from server...")
	
	if is_connected:
		# Kirim unregister message
		var unregister_message = "UNREGISTER".to_utf8_buffer()
		udp_client.put_packet(unregister_message)
	
	is_connected = false
	udp_client.close()
	frame_buffers.clear()
	
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

func receive_packets():
	var packet_count = udp_client.get_available_packet_count()
	
	for i in range(packet_count):
		var packet = udp_client.get_packet()
		if packet.size() >= 12:  # Minimal header size
			packets_received += 1
			bytes_received += packet.size()
			process_packet(packet)

func process_packet(packet: PackedByteArray):
	# Parse header: [sequence_number:4][total_packets:4][packet_index:4][data...]
	if packet.size() < 12:
		return
	
	var sequence_number = bytes_to_int(packet.slice(0, 4))
	var total_packets = bytes_to_int(packet.slice(4, 8))
	var packet_index = bytes_to_int(packet.slice(8, 12))
	var packet_data = packet.slice(12)
	
	# Validasi data
	if total_packets <= 0 or packet_index >= total_packets or sequence_number <= 0:
		print("⚠️  Invalid packet header: seq=", sequence_number, " total=", total_packets, " index=", packet_index)
		return
	
	# Skip frame lama (lebih dari 2 frame di belakang)
	if sequence_number < last_completed_sequence - 2:
		return
	
	# Inisialisasi buffer untuk frame baru
	if sequence_number not in frame_buffers:
		frame_buffers[sequence_number] = {
			"total_packets": total_packets,
			"received_packets": 0,
			"data_parts": {},
			"timestamp": Time.get_ticks_msec() / 1000.0
		}
	
	var frame_buffer = frame_buffers[sequence_number]
	
	# Tambahkan packet ke frame buffer (jika belum ada)
	if packet_index not in frame_buffer.data_parts:
		frame_buffer.data_parts[packet_index] = packet_data
		frame_buffer.received_packets += 1
		
		# Cek apakah frame sudah lengkap
		if frame_buffer.received_packets == frame_buffer.total_packets:
			assemble_and_display_frame(sequence_number)

func assemble_and_display_frame(sequence_number: int):
	if sequence_number not in frame_buffers:
		return
	
	var frame_buffer = frame_buffers[sequence_number]
	var frame_data = PackedByteArray()
	
	# Gabungkan semua packet sesuai urutan
	for i in range(frame_buffer.total_packets):
		if i in frame_buffer.data_parts:
			frame_data.append_array(frame_buffer.data_parts[i])
		else:
			print("❌ Missing packet ", i, " for frame ", sequence_number)
			frames_dropped += 1
			frame_buffers.erase(sequence_number)
			return
	
	# Hapus dari buffer
	frame_buffers.erase(sequence_number)
	last_completed_sequence = sequence_number
	frames_completed += 1
	
	# Display frame
	display_frame(frame_data)
	
	# Debug info setiap 30 frame
	if frames_completed % 30 == 0:
		var drop_rate = float(frames_dropped) / float(frames_completed + frames_dropped) * 100.0
		print("📊 Frame ", sequence_number, " completed. Drop rate: %.1f%%" % drop_rate)

func cleanup_old_frames():
	var current_time = Time.get_ticks_msec() / 1000.0
	var sequences_to_remove = []
	
	for seq_num in frame_buffers:
		var frame_buffer = frame_buffers[seq_num]
		if current_time - frame_buffer.timestamp > frame_timeout:
			sequences_to_remove.append(seq_num)
			frames_dropped += 1
	
	for seq_num in sequences_to_remove:
		frame_buffers.erase(seq_num)
		if sequences_to_remove.size() > 0:
			print("🗑️  Cleaned up ", sequences_to_remove.size(), " timed out frames")

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
		print("❌ Error loading image: ", error)

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
		data_rate_label.text = "Rate: %.1f KB/s" % current_data_rate
		
		# Tambahkan statistik packet
		if frames_completed + frames_dropped > 0:
			var drop_rate = float(frames_dropped) / float(frames_completed + frames_dropped) * 100.0
			status_label.text = "Status: Connected - Packets: %d, Drop: %.1f%%" % [packets_received, drop_rate]
	else:
		fps_label.text = "FPS: --"
		resolution_label.text = "Resolution: --"
		data_rate_label.text = "Rate: -- KB/s"

func update_status(message: String):
	status_label.text = "Status: " + message
	print("🎮 Webcam Client: " + message)

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if is_connected:
			disconnect_from_server()
		get_tree().quit()
