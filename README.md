# app_mushroom

App Flutter cho bài toán nhận diện nấm, gọi trực tiếp backend theo luồng trong `server.py`.

## Tính năng

- Upload ảnh từ thư viện.
- Chụp ảnh trực tiếp bằng camera.
- Quay video bằng camera và tự động chọn frame có chất lượng tốt nhất trước khi đưa vào hàng chờ.
- Upload ảnh thật qua API `POST /api/images/upload` để tạo job.
- Theo dõi trạng thái qua WebSocket `ws://<backend-ip>:8000/ws/queue`.
- Poll trạng thái job qua `GET /api/jobs/{job_id}` làm đường dự phòng.

## Cách hoạt động

- Chọn ảnh từ thư viện, camera, hoặc trích frame tốt nhất từ video.
- Gửi ảnh lên backend bằng multipart/form-data với field `file`.
- Nhận `job_id` và cập nhật tiến trình theo realtime event (`queue.snapshot`, `queue.status`, `job.status`, `job.result`).
- Nếu WS gián đoạn hoặc chưa có event, app vẫn poll trạng thái job định kỳ.

## Cấu hình backend

- Chạy backend FastAPI trước (file tham chiếu: `server.py`).
- Trong app, nhập URL backend tại ô **Backend URL** và bấm **Áp dụng & kết nối WS**.
- Ví dụ:
	- Android emulator: `http://10.0.2.2:8000`
	- iOS simulator: `http://127.0.0.1:8000`
	- Thiết bị thật: `http://<LAN-IP-của-máy-chạy-backend>:8000`

## Chạy dự án

1. `flutter pub get`
2. `flutter run`

## Ghi chú kỹ thuật

- Chọn frame tốt nhất từ video bằng cách:
	- Lấy nhiều frame mẫu theo timeline video.
	- Tính điểm chất lượng dựa trên độ nét (gradient) và phơi sáng.
	- Chọn frame có điểm cao nhất.
- WebSocket có cơ chế tự reconnect khi mất kết nối; app vẫn poll trạng thái job đang chạy định kỳ để giảm rủi ro miss event.
