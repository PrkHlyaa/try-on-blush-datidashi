#!/usr/bin/env python3
"""
UDP Webcam Server - Enhanced Blush On with Multi-face Detection
"""

import cv2
import socket
import struct
import threading
import time
import math
import numpy as np
import mediapipe as mp
from scipy.interpolate import splprep, splev
from scipy.ndimage import gaussian_filter

class UDPWebcamServer:
    def __init__(self, host='127.0.0.1', port=8888, control_port=8889):
        self.host = host
        self.port = port
        self.control_port = control_port
        self.server_socket = None
        self.control_socket = None
        self.clients = set()
        self.camera = None
        self.running = False
        self.sequence_number = 0

        # Optimized settings
        self.max_packet_size = 32768
        self.target_fps = 15
        self.jpeg_quality = 40
        self.frame_width = 640
        self.frame_height = 480

        # Performance monitoring
        self.frame_send_time = 1.0 / self.target_fps

        # --- Inisialisasi Mediapipe Face Mesh ---
        self.mp_face_mesh = mp.solutions.face_mesh
        self.face_mesh = self.mp_face_mesh.FaceMesh(
            max_num_faces=5,  # Support multiple faces
            refine_landmarks=True,
            min_detection_confidence=0.5,
            min_tracking_confidence=0.5)
        self.mp_drawing = mp.solutions.drawing_utils
        # ----------------------------------------

        # --- Blush Settings (dapat diubah via control socket) ---
        self.blush_color_rgb = (235, 148, 146)  # Pink natural (RGB format)
        self.blush_intensity = 0.25  # Lebih tipis untuk natural look
        self.blush_blur = 15  # Gaussian blur radius untuk softness
        self.lock = threading.Lock()  # Thread safety untuk update settings
        # ---------------------------------------------------------

    def initialize_camera(self):
        print("🎥 Initializing optimized camera...")
        self.camera = cv2.VideoCapture(0, cv2.CAP_DSHOW)

        if self.camera.isOpened():
            self.camera.set(cv2.CAP_PROP_FRAME_WIDTH, self.frame_width)
            self.camera.set(cv2.CAP_PROP_FRAME_HEIGHT, self.frame_height)
            self.camera.set(cv2.CAP_PROP_FPS, self.target_fps)
            actual_width = int(self.camera.get(cv2.CAP_PROP_FRAME_WIDTH))
            actual_height = int(self.camera.get(cv2.CAP_PROP_FRAME_HEIGHT))
            actual_fps = self.camera.get(cv2.CAP_PROP_FPS)
            print(f"✅ Camera initialized: {actual_width}x{actual_height} @ {actual_fps:.2f} FPS")
            return True
        else:
            print("❌ Failed to initialize camera")
            return False

    def listen_for_clients(self):
        """ Listens for incoming client messages """
        print(f"👂 Listening for clients on {self.host}:{self.port}...")
        while self.running:
            try:
                data, addr = self.server_socket.recvfrom(1024)
                message = data.decode('utf-8')

                if addr not in self.clients and message == "REGISTER":
                    print(f"➕ New client connected: {addr}")
                    self.clients.add(addr)
                    self.server_socket.sendto(b"REGISTERED", addr)
                    print(f"✅ Sent registration confirmation to {addr}")
                elif message == "UNREGISTER" and addr in self.clients:
                    print(f"➖ Client disconnected: {addr}")
                    self.clients.discard(addr)

            except socket.timeout:
                continue
            except Exception as e:
                if self.running:
                    print(f"❌ Listener error: {e}")
                break

    def listen_for_controls(self):
        """ Listens for control commands to update blush settings """
        print(f"🎮 Control socket listening on {self.host}:{self.control_port}...")
        while self.running:
            try:
                data, addr = self.control_socket.recvfrom(1024)
                command = data.decode('utf-8').strip()
                
                if command.startswith("COLOR:"):
                    # Format: COLOR:R,G,B (e.g., COLOR:255,100,150)
                    try:
                        rgb_str = command.split(":")[1]
                        r, g, b = map(int, rgb_str.split(","))
                        with self.lock:
                            self.blush_color_rgb = (r, g, b)
                        print(f"🎨 Blush color updated to RGB({r}, {g}, {b})")
                        self.control_socket.sendto(b"COLOR_OK", addr)
                    except Exception as e:
                        print(f"❌ Invalid color format: {e}")
                        self.control_socket.sendto(b"COLOR_ERROR", addr)
                
                elif command.startswith("INTENSITY:"):
                    # Format: INTENSITY:0.25 (range 0.0-1.0)
                    try:
                        intensity = float(command.split(":")[1])
                        intensity = max(0.0, min(1.0, intensity))
                        with self.lock:
                            self.blush_intensity = intensity
                        print(f"💪 Blush intensity updated to {intensity:.2f}")
                        self.control_socket.sendto(b"INTENSITY_OK", addr)
                    except Exception as e:
                        print(f"❌ Invalid intensity format: {e}")
                        self.control_socket.sendto(b"INTENSITY_ERROR", addr)
                
                elif command.startswith("BLUR:"):
                    # Format: BLUR:15 (pixels)
                    try:
                        blur = int(command.split(":")[1])
                        blur = max(5, min(50, blur))
                        with self.lock:
                            self.blush_blur = blur
                        print(f"🌫️ Blush blur updated to {blur}px")
                        self.control_socket.sendto(b"BLUR_OK", addr)
                    except Exception as e:
                        print(f"❌ Invalid blur format: {e}")
                        self.control_socket.sendto(b"BLUR_ERROR", addr)

            except socket.timeout:
                continue
            except Exception as e:
                if self.running:
                    print(f"❌ Control listener error: {e}")

    def get_cheek_contour_points(self, face_landmarks, w, h, is_left=True):
        """
        Mendapatkan titik-titik kontur pipi yang lebih presisi
        """
        if is_left:
            # Pipi kiri - area blush yang lebih kecil (zygomatic region)
            indices = [
                116, 117, 118, 119, 100,  # Area tulang pipi atas
                47, 126, 209,  # Area tengah pipi
                50, 101, 205, 187, # Area bawah pipi (menghindari dagu)
                # 207, 108, 69,  # Area bawah pipi (menghindari dagu)
                # 104, 67, 105, 66, 107 # Tambahan untuk memperluas area bawah
            ]
        else:
            # Pipi kanan - area blush yang lebih kecil (zygomatic region)
            indices = [
                345, 346, 347, 348, 329,  # Area tulang pipi atas
                277, 355, 429,  # Area tengah pipi
                280, 330, 425, 411, # Area bawah pipi (menghindari dagu)
                # 427, 337, 299, # Area bawah pipi (menghindari dagu)
                # 334, 297, 333, 296, 336 # Tambahan untuk memperluas area bawah
            ]

        points = []
        for idx in indices:
            if idx < len(face_landmarks.landmark):
                lm = face_landmarks.landmark[idx]
                points.append((int(lm.x * w), int(lm.y * h)))

        return np.array(points, dtype=np.int32)

    def create_smooth_blush_mask(self, frame_shape, points, blur_radius):
        """
        Membuat mask blush yang smooth dengan gradient natural
        """
        h, w = frame_shape[:2]
        mask = np.zeros((h, w), dtype=np.float32)
        
        if len(points) < 3:
            return mask
        
        # Buat convex hull dari points untuk area blush
        hull = cv2.convexHull(points)
        cv2.fillConvexPoly(mask, hull, 1.0)
        
        # Apply gaussian blur untuk smooth transition
        mask = gaussian_filter(mask, sigma=blur_radius)
        
        # Normalize mask
        if mask.max() > 0:
            mask = mask / mask.max()
        
        return mask

    def apply_blush(self, frame):
        """
        Aplikasi blush yang natural dengan deteksi multi-wajah
        """
        output_frame = frame.copy().astype(np.float32)
        
        # Konversi BGR ke RGB untuk Mediapipe
        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        rgb_frame.flags.writeable = False
        results = self.face_mesh.process(rgb_frame)
        rgb_frame.flags.writeable = True

        if results.multi_face_landmarks:
            h, w, _ = frame.shape
            
            # Get current settings with thread safety
            with self.lock:
                color_rgb = self.blush_color_rgb
                intensity = self.blush_intensity
                blur = self.blush_blur
            
            # Convert RGB to BGR for OpenCV
            color_bgr = (color_rgb[2], color_rgb[1], color_rgb[0])
            
            # Process each detected face
            for face_idx, face_landmarks in enumerate(results.multi_face_landmarks):
                
                # Get cheek contour points
                left_cheek_points = self.get_cheek_contour_points(face_landmarks, w, h, is_left=True)
                right_cheek_points = self.get_cheek_contour_points(face_landmarks, w, h, is_left=False)
                
                # Create smooth masks for both cheeks
                left_mask = self.create_smooth_blush_mask((h, w), left_cheek_points, blur)
                right_mask = self.create_smooth_blush_mask((h, w), right_cheek_points, blur)
                
                # Combine masks
                combined_mask = np.maximum(left_mask, right_mask)
                
                # Apply mask intensity
                combined_mask = combined_mask * intensity
                
                # Create color overlay
                color_overlay = np.zeros_like(output_frame)
                color_overlay[:, :] = color_bgr
                
                # Blend dengan frame menggunakan mask
                for c in range(3):
                    output_frame[:, :, c] = (
                        output_frame[:, :, c] * (1 - combined_mask) +
                        color_overlay[:, :, c] * combined_mask
                    )
        
        return output_frame.astype(np.uint8)

    def send_frames(self):
        """ Captures frames, applies blush, encodes, packets, and sends them """
        print("🚀 Starting frame broadcast...")

        while self.running:
            start_capture_time = time.time()

            ret, frame = self.camera.read()
            if not ret:
                print("⚠️ Dropped frame")
                time.sleep(0.01)
                continue

            # Aplikasikan Blush On
            frame_with_blush = self.apply_blush(frame)

            # Encode frame ke JPEG
            encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), self.jpeg_quality]
            result, encoded_frame = cv2.imencode('.jpg', frame_with_blush, encode_param)

            if not result:
                print("❌ JPEG encoding failed")
                continue

            frame_data = encoded_frame.tobytes()
            frame_size = len(frame_data)
            self.sequence_number += 1

            # Packetization
            header_size = 12
            payload_size = self.max_packet_size - header_size
            total_packets = math.ceil(frame_size / payload_size)

            # Send to all clients
            current_clients = self.clients.copy()
            for client_addr in current_clients:
                try:
                    for packet_index in range(total_packets):
                        start_pos = packet_index * payload_size
                        end_pos = min(start_pos + payload_size, frame_size)

                        header = struct.pack("!III", self.sequence_number, total_packets, packet_index)
                        udp_packet = header + frame_data[start_pos:end_pos]

                        self.server_socket.sendto(udp_packet, client_addr)

                    if self.sequence_number % (self.target_fps * 2) == 1:
                        print(f"📤 Frame {self.sequence_number} ({frame_size // 1024} KB) → {len(current_clients)} clients")

                except socket.error as se:
                    print(f"❌ Socket error sending to {client_addr}: {se}")
                    self.clients.discard(client_addr)
                except Exception as e:
                    print(f"❌ Unexpected error sending to {client_addr}: {e}")
                    self.clients.discard(client_addr)

            # Frame rate control
            elapsed_time = time.time() - start_capture_time
            sleep_time = self.frame_send_time - elapsed_time
            if sleep_time > 0:
                time.sleep(sleep_time)

    def start_server(self):
        if self.running:
            print("⚠️ Server already running")
            return

        print(f"🟢 Starting UDP server on {self.host}:{self.port}...")
        self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.server_socket.bind((self.host, self.port))
        self.server_socket.settimeout(0.5)

        # Setup control socket
        print(f"🎮 Starting control socket on {self.host}:{self.control_port}...")
        self.control_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.control_socket.bind((self.host, self.control_port))
        self.control_socket.settimeout(0.5)

        if not self.initialize_camera():
            self.server_socket.close()
            self.control_socket.close()
            return

        self.running = True
        self.sequence_number = 0

        # Start listener threads
        self.listener_thread = threading.Thread(target=self.listen_for_clients, daemon=True)
        self.listener_thread.start()

        self.control_thread = threading.Thread(target=self.listen_for_controls, daemon=True)
        self.control_thread.start()

        # Start frame sending
        try:
            self.send_frames()
        except KeyboardInterrupt:
            print("\n⌨️ Ctrl+C detected. Stopping server...")
        finally:
            self.stop_server()

    def stop_server(self):
        print("⏹️ Stopping server...")
        self.running = False
        time.sleep(0.1)

        if self.server_socket:
            self.server_socket.close()
            self.server_socket = None
        if self.control_socket:
            self.control_socket.close()
            self.control_socket = None
        if self.camera:
            self.camera.release()
            self.camera = None

        print("✅ Server stopped")

if __name__ == "__main__":
    print("=== UDP Webcam Server with Enhanced Blush On ===")
    print("📝 Install dependencies: pip install opencv-python mediapipe scipy numpy")
    server = UDPWebcamServer()
    try:
        server.start_server()
    except Exception as e:
        print(f"💥 Unhandled exception: {e}")
        server.stop_server()