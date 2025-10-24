extends Node
class_name WebcamClient

# Sinyal untuk komunikasi dengan UI
signal frame_received(texture: ImageTexture)
signal connection_status_changed(connected: bool)
signal error_occurred(message: String)

var tcp_client: StreamPeerTCP
var thread: Thread
var running: bool = false
var connected: bool = false
var server_host: String = "127.0.0.1"
var server_port: int = 9999

# Buffer untuk menerima data
var receive_buffer: PackedByteArray
var expected_data_size: int = 0
var waiting_for_header: bool = true

func _init():
	tcp_client = StreamPeerTCP.new()
	thread = Thread.new()

func connect_to_server() -> bool:
	"""Koneksi ke webcam server"""
	if connected:
		print("Sudah terhubung ke server")
		return true
	
	print("Mencoba koneksi ke webcam server...")
	var error = tcp_client.connect_to_host(server_host, server_port)
	
	if error != OK:
		emit_signal("error_occurred", "Gagal memulai koneksi: " + str(error))
		return false
	
	# Tunggu koneksi
	var timeout = 5.0  # 5 detik timeout
	var start_time = Time.get_time_dict_from_system()
	
	while tcp_client.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		await get_tree().process_frame
		var current_time = Time.get_time_dict_from_system()
		var elapsed = (current_time.hour * 3600 + current_time.minute * 60 + current_time.second) - \
					 (start_time.hour * 3600 + start_time.minute * 60 + start_time.second)
		
		if elapsed > timeout:
			emit_signal("error_occurred", "Timeout koneksi ke server")
			tcp_client.disconnect_from_host()
			return false
	
	if tcp_client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		connected = true
		running = true
		
		# Mulai thread untuk menerima data
		thread.start(_receive_thread)
		
		emit_signal("connection_status_changed", true)
		print("Berhasil terhubung ke webcam server")
		return true
	else:
		emit_signal("error_occurred", "Gagal terhubung ke server")
		return false

func disconnect_from_server():
	"""Putuskan koneksi dari server"""
	if not connected:
		return
	
	print("Memutuskan koneksi dari webcam server...")
	running = false
	connected = false
	
	tcp_client.disconnect_from_host()
	
	# Tunggu thread selesai
	if thread.is_started():
		thread.wait_to_finish()
	
	emit_signal("connection_status_changed", false)
	print("Koneksi terputus")

func _receive_thread():
	"""Thread untuk menerima data dari server"""
	receive_buffer = PackedByteArray()
	waiting_for_header = true
	expected_data_size = 0
	
	while running and connected:
		var status = tcp_client.get_status()
		
		if status != StreamPeerTCP.STATUS_CONNECTED:
			print("Koneksi terputus dari server")
			call_deferred("_on_connection_lost")
			break
		
		var available_bytes = tcp_client.get_available_bytes()
		if available_bytes > 0:
			var data = tcp_client.get_data(available_bytes)[1]
			receive_buffer.append_array(data)
			
			# Process received data
			_process_received_data()
		else:
			# Jeda singkat untuk menghindari busy loop
			OS.delay_msec(1)

func _process_received_data():
	"""Proses data yang diterima"""
	while true:
		if waiting_for_header:
			# Tunggu header 4 bytes (ukuran data)
			if receive_buffer.size() >= 4:
				var size_bytes = receive_buffer.slice(0, 4)
				expected_data_size = size_bytes.decode_u32(0)  # Big endian
				
				# Hapus header dari buffer
				receive_buffer = receive_buffer.slice(4)
				waiting_for_header = false
			else:
				break  # Belum cukup data untuk header
		else:
			# Tunggu data JSON sesuai ukuran yang diharapkan
			if receive_buffer.size() >= expected_data_size:
				var json_bytes = receive_buffer.slice(0, expected_data_size)
				var json_string = json_bytes.get_string_from_utf8()
				
				# Hapus data yang sudah diproses dari buffer
				receive_buffer = receive_buffer.slice(expected_data_size)
				
				# Reset untuk frame berikutnya
				waiting_for_header = true
				expected_data_size = 0
				
				# Proses frame
				call_deferred("_process_frame_data", json_string)
			else:
				break  # Belum cukup data

func _process_frame_data(json_string: String):
	"""Proses data frame dari JSON"""
	var json = JSON.new()
	var parse_result = json.parse(json_string)
	
	if parse_result != OK:
		emit_signal("error_occurred", "Error parsing JSON frame data")
		return
	
	var frame_data = json.data
	
	if not frame_data.has("type") or frame_data.type != "frame":
		return
	
	if not frame_data.has("data") or not frame_data.has("width") or not frame_data.has("height"):
		emit_signal("error_occurred", "Frame data tidak lengkap")
		return
	
	# Decode base64 image data
	var image_data = Marshalls.base64_to_raw(frame_data.data)
	
	# Buat image dari JPEG data
	var image = Image.new()
	var load_result = image.load_jpg_from_buffer(image_data)
	
	if load_result != OK:
		emit_signal("error_occurred", "Gagal load image dari buffer")
		return
	
	# Buat texture dari image
	var texture = ImageTexture.new()
	texture.set_image(image)
	
	# Emit signal dengan texture
	emit_signal("frame_received", texture)

func _on_connection_lost():
	"""Handle ketika koneksi terputus"""
	if connected:
		connected = false
		running = false
		emit_signal("connection_status_changed", false)
		emit_signal("error_occurred", "Koneksi ke server terputus")

func is_webcam_connected() -> bool:
	"""Cek apakah masih terhubung"""
	return connected and tcp_client.get_status() == StreamPeerTCP.STATUS_CONNECTED

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		disconnect_from_server()
