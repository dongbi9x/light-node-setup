#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Vui lòng chạy script này với quyền người dùng root"
  exit 1
fi

WORK_DIR="/root/light-node"
echo "Thư mục làm việc: $WORK_DIR"

echo "Cài đặt các công cụ cơ bản (git, curl, netcat)..."
apt update
apt install -y git curl netcat-openbsd

if [ -d "$WORK_DIR" ]; then
  echo "Phát hiện $WORK_DIR đã tồn tại, đang thử cập nhật..."
  cd $WORK_DIR
  git pull
else
  echo "Sao chép kho Layer Edge Light Node..."
  git clone https://github.com/Layer-Edge/light-node.git $WORK_DIR
  cd $WORK_DIR
fi
if [ $? -ne 0 ]; then
  echo "Sao chép hoặc cập nhật kho thất bại, vui lòng kiểm tra mạng hoặc quyền"
  exit 1
fi

if ! command -v rustc &> /dev/null; then
  echo "Cài đặt Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source $HOME/.cargo/env
fi
rust_version=$(rustc --version)
echo "Phiên bản Rust hiện tại: $rust_version"

echo "Cài đặt trình quản lý chuỗi công cụ RISC0 (rzup)..."
curl -L https://risczero.com/install | bash
export PATH=$PATH:/root/.risc0/bin
echo 'export PATH=$PATH:/root/.risc0/bin' >> /root/.bashrc
source /root/.bashrc
if ! command -v rzup &> /dev/null; then
  echo "Cài đặt rzup thất bại, vui lòng kiểm tra mạng hoặc cài đặt thủ công"
  exit 1
fi
echo "Cài đặt chuỗi công cụ RISC0..."
rzup install
rzup_version=$(rzup --version)
echo "Phiên bản rzup hiện tại: $rzup_version"

echo "Đang cài đặt/nâng cấp Go lên 1.23.1..."
wget -q https://go.dev/dl/go1.23.1.linux-amd64.tar.gz -O /tmp/go1.23.1.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go1.23.1.tar.gz
export PATH=/usr/local/go/bin:$PATH
echo 'export PATH=/usr/local/go/bin:$PATH' >> /root/.bashrc
source /root/.bashrc
go_version=$(go version)
echo "Phiên bản Go hiện tại: $go_version"

if ! command -v go &> /dev/null; then
  echo "Cài đặt Go thất bại, vui lòng kiểm tra mạng hoặc cài đặt thủ công"
  exit 1
fi
if [[ "$go_version" != *"go1.23"* ]]; then
  echo "Phiên bản Go chưa được nâng cấp lên 1.23.1, vui lòng kiểm tra các bước cài đặt"
  exit 1
fi

echo "Vui lòng nhập PRIVATE_KEY của bạn bên dưới (chuỗi thập lục phân 64 bit, nhấn Enter sau khi nhập):"
read -r PRIVATE_KEY
if [ -z "$PRIVATE_KEY" ] || [ ${#PRIVATE_KEY} -ne 64 ]; then
  echo "Khóa riêng không hợp lệ, phải là chuỗi thập lục phân 64 bit, vui lòng chạy lại script"
  exit 1
fi

echo "Vui lòng nhập GRPC_URL của bạn bên dưới (mặc định 34.31.74.109:9090, nhấn Enter sau khi nhập hoặc nhấn Enter để dùng mặc định):"
read -r GRPC_URL
if [ -z "$GRPC_URL" ]; then
  GRPC_URL="34.31.74.109:9090"
fi

echo "Chọn ZK_PROVER_URL (nhập 1 để dùng local http://127.0.0.1:3001, nhập 2 để dùng https://layeredge.mintair.xyz/, nhấn Enter mặc định 1):"
read -r ZK_CHOICE
if [ "$ZK_CHOICE" = "2" ]; then
  ZK_PROVER_URL="https://layeredge.mintair.xyz/"
else
  ZK_PROVER_URL="http://127.0.0.1:3001"
fi

echo "Kiểm tra khả năng kết nối GRPC_URL: $GRPC_URL..."
GRPC_HOST=$(echo $GRPC_URL | cut -d: -f1)
GRPC_PORT=$(echo $GRPC_URL | cut -d: -f2)
nc -zv $GRPC_HOST $GRPC_PORT
if [ $? -ne 0 ]; then
  echo "Cảnh báo: Không thể kết nối đến $GRPC_URL, vui lòng xác nhận địa chỉ đúng hoặc thử lại sau"
fi

echo "Thiết lập biến môi trường..."
cat << EOF > $WORK_DIR/.env
GRPC_URL=$GRPC_URL
CONTRACT_ADDR=cosmos1ufs3tlq4umljk0qfe8k5ya0x6hpavn897u2cnf9k0en9jr7qarqqt56709
ZK_PROVER_URL=$ZK_PROVER_URL
API_REQUEST_TIMEOUT=100
POINTS_API=https://light-node.layeredge.io
PRIVATE_KEY='$PRIVATE_KEY'
EOF
if [ ! -f "$WORK_DIR/.env" ]; then
  echo "Tạo tệp .env thất bại, vui lòng kiểm tra quyền hoặc dung lượng đĩa"
  exit 1
fi
echo "Biến môi trường đã được ghi vào $WORK_DIR/.env"
cat $WORK_DIR/.env

echo "Xây dựng và khởi động risc0-merkle-service..."
cd $WORK_DIR/risc0-merkle-service
cargo build
if [ $? -ne 0 ]; then
  echo "Xây dựng risc0-merkle-service thất bại, vui lòng kiểm tra môi trường Rust và RISC0"
  exit 1
fi
cargo run > risc0.log 2>&1 &
RISC0_PID=$!
echo "risc0-merkle-service đã khởi động, PID: $RISC0_PID, nhật ký xuất ra risc0.log"

sleep 5
if ! ps -p $RISC0_PID > /dev/null; then
  echo "Khởi động risc0-merkle-service thất bại, vui lòng kiểm tra $WORK_DIR/risc0-merkle-service/risc0.log"
  cat $WORK_DIR/risc0-merkle-service/risc0.log
  exit 1
fi

echo "Xây dựng và khởi động light-node..."
cd $WORK_DIR
go mod tidy
go build
if [ $? -ne 0 ]; then
  echo "Xây dựng light-node thất bại, vui lòng kiểm tra môi trường Go hoặc các phụ thuộc"
  exit 1
fi

source $WORK_DIR/.env
./light-node > light-node.log 2>&1 &
LIGHT_NODE_PID=$!
echo "light-node đã khởi động, PID: $LIGHT_NODE_PID, nhật ký xuất ra light-node.log"

sleep 5
if ! ps -p $LIGHT_NODE_PID > /dev/null; then
  echo "Khởi động light-node thất bại, vui lòng kiểm tra $WORK_DIR/light-node.log"
  cat $WORK_DIR/light-node.log
  exit 1
fi

echo "Tất cả dịch vụ đã khởi động!"
echo "Kiểm tra nhật ký:"
echo "- risc0-merkle-service: $WORK_DIR/risc0-merkle-service/risc0.log"
echo "- light-node: $WORK_DIR/light-node.log"
echo "Nếu cần kết nối bảng điều khiển, hãy truy cập dashboard.layeredge.io và sử dụng khóa công khai để liên kết"