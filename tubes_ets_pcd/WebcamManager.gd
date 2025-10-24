extends Node

signal frame_received(texture: ImageTexture)
signal connection_changed(connected: bool) 
signal error_message(message: String)

var tcp_client: StreamPeerTCP
var webcam_connected: bool = false
var server_host: String = "127.0.0.1"
var server_port: int = 8081

# Buffer untuk menyimpan data yang diterima
var receive_buffer: PackedByteArray = PackedByteArray()
var waiting_for_header: bool = true
var expected_data_size: int = 0

func _ready():
	connect_to_webcam_server()

func connect_to_webcam_server():
	tcp_client = StreamPeerTCP.new()
	var result = tcp_client.connect_to_host(server_host, server_port)
	if result == OK:
		print("✅ Connecting to webcam server...")
		set_process(true)

func _process(_delta):
	if not tcp_client:
		return
	
	var status = tcp_client.get_status()
	
	if status == StreamPeerTCP.STATUS_CONNECTED:
		if not webcam_connected:
			webcam_connected = true
			connection_changed.emit(true)
			print("✅ Webcam server connected!")
		
		# Baca data yang tersedia (non-blocking)
		var available = tcp_client.get_available_bytes()
		if available > 0:
			var data = tcp_client.get_partial_data(available)
			if data[0] == OK:
				receive_buffer.append_array(data[1])
				_process_buffer()
	
	elif status == StreamPeerTCP.STATUS_ERROR:
		print("❌ Connection error")
		disconnect_from_server()
	elif status == StreamPeerTCP.STATUS_NONE:
		print("❌ Connection lost")
		disconnect_from_server()

func _process_buffer():
	while true:
		if waiting_for_header:
			# Perlu 4 bytes untuk header
			if receive_buffer.size() >= 4:
				# Parse frame size (big endian)
				expected_data_size = (receive_buffer[0] << 24) | \
									(receive_buffer[1] << 16) | \
									(receive_buffer[2] << 8) | \
									receive_buffer[3]
				
				# Remove header dari buffer
				receive_buffer = receive_buffer.slice(4)
				waiting_for_header = false
				print("📋 Frame size: " + str(expected_data_size))
			else:
				break # Belum cukup data
		else:
			# Perlu data sesuai ukuran frame
			if receive_buffer.size() >= expected_data_size:
				# Extract frame data
				var frame_data = receive_buffer.slice(0, expected_data_size)
				receive_buffer = receive_buffer.slice(expected_data_size)
				
				# Reset untuk frame berikutnya
				waiting_for_header = true
				expected_data_size = 0
				
				# Process frame
				_process_frame(frame_data)
			else:
				break # Belum cukup data

func _process_frame(jpeg_data: PackedByteArray):
	if jpeg_data.size() > 0:
		var image = Image.new()
		var load_error = image.load_jpg_from_buffer(jpeg_data)
		if load_error == OK:
			var texture = ImageTexture.new()
			texture.set_image(image)
			frame_received.emit(texture)
			print("🖼️ Frame processed: " + str(image.get_width()) + "x" + str(image.get_height()))
		else:
			print("❌ JPEG load error: " + str(load_error))

func disconnect_from_server():
	if tcp_client:
		tcp_client.disconnect_from_host()
		tcp_client = null
	webcam_connected = false
	connection_changed.emit(false)
	set_process(false)
	receive_buffer.clear()
	waiting_for_header = true
	expected_data_size = 0

func _emit_error(message: String):
	error_message.emit(message)

func get_connection_status() -> bool:
	return webcam_connected

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		disconnect_from_server()
