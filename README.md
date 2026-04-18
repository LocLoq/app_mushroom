# app_mushroom

App Flutter mẫu cho bài toán nhận diện nấm, gọi trực tiếp backend theo luồng từ `server.py`.

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

- Sửa hằng số `kBackendIp` trong `lib/app.dart` để trỏ tới IP backend của bạn.
- Port mặc định là `8000` (hằng số `kBackendPort`).

## Chạy dự án

1. `flutter pub get`
2. `flutter run`

## Ghi chú kỹ thuật

- Chọn frame tốt nhất từ video bằng cách:
	- Lấy nhiều frame mẫu theo timeline video.
	- Tính điểm chất lượng dựa trên độ nét (gradient) và phơi sáng.
	- Chọn frame có điểm cao nhất.
- Khi bạn muốn nối API thật, có thể thay `MockQueueWebSocketService` bằng service gọi HTTP + WebSocket thật, còn UI gần như giữ nguyên.
