# app_mushroom

App Flutter mẫu cho bài toán nhận diện nấm, tham chiếu luồng từ `server.py` nhưng hiện tại chưa gọi API thật.

## Tính năng

- Upload ảnh từ thư viện.
- Chụp ảnh trực tiếp bằng camera.
- Quay video bằng camera và tự động chọn frame có chất lượng tốt nhất trước khi đưa vào hàng chờ.
- Hàng chờ xử lý job theo thứ tự FIFO (mô phỏng local).
- WebSocket event mô phỏng để theo dõi queue realtime (`queue.snapshot`, `queue.status`, `job.status`, `job.result`, `pong`).

## Cách hoạt động (mock)

- App chưa gọi endpoint `/api/images/upload` hay `/api/jobs/{job_id}`.
- Dữ liệu ảnh/frame được xử lý local để giả lập kết quả nhận diện (`nam_huong`, `nam_kim_cham`).
- Event queue được phát qua stream nội bộ theo định dạng tương tự server.

## Chạy dự án

1. `flutter pub get`
2. `flutter run`

## Ghi chú kỹ thuật

- Chọn frame tốt nhất từ video bằng cách:
	- Lấy nhiều frame mẫu theo timeline video.
	- Tính điểm chất lượng dựa trên độ nét (gradient) và phơi sáng.
	- Chọn frame có điểm cao nhất.
- Khi bạn muốn nối API thật, có thể thay `MockQueueWebSocketService` bằng service gọi HTTP + WebSocket thật, còn UI gần như giữ nguyên.
