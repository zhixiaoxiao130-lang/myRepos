#!/usr/bin/env python3
"""
RK3588 NPU 综合测试工具（v8 - 自动部署 librknnrt.so & Python 源码编译指引）
功能：
  1. 纯 NPU 推理测试 (MobileNet-v1)
  2. CSI 摄像头实时分类
  3. NPU 压力测试 (YOLOv5s)
环境自检：自动部署运行时库、智能处理 Python 版本不匹配。
"""

import os, sys, time, subprocess, multiprocessing, re, shutil
from multiprocessing import Process, Value, Event
from ctypes import c_ulonglong
from datetime import datetime

# ================= 终端格式化 =================
BOLD = '\033[1m'
RED = '\033[91m'
GREEN = '\033[92m'
YELLOW = '\033[93m'
CYAN = '\033[96m'
NC = '\033[0m'

def print_bold(text):
    print(f"{BOLD}{text}{NC}")

def print_ok(text):
    print(f"{GREEN}✅ {text}{NC}")

def print_err(text):
    print(f"{RED}❌ {text}{NC}")

def print_warn(text):
    print(f"{YELLOW}⚠️  {text}{NC}")

def print_info(text):
    print(f"{CYAN}ℹ️  {text}{NC}")

def print_section(title):
    print(f"\n{BOLD}{'='*55}{NC}")
    print(f"{BOLD}{title}{NC}")
    print(f"{BOLD}{'='*55}{NC}")

# ================= 动态库自动部署 =================
def try_auto_deploy_librknnrt():
    """
    如果当前目录存在 librknnrt.so，但系统库路径中未找到，
    自动尝试复制到 /usr/lib/ 并执行 ldconfig。
    返回 True 表示部署成功或已经存在，False 表示需要手动处理。
    """
    # 先检查系统库中是否已有
    if check_librknnrt():
        return True

    local_so = os.path.join(os.getcwd(), 'librknnrt.so')
    if not os.path.exists(local_so):
        return False  # 当前目录也没有，无法自动部署

    print_warn("当前目录存在 librknnrt.so，但系统库路径中未找到，尝试自动部署...")
    try:
        subprocess.run(['sudo', 'cp', local_so, '/usr/lib/'], check=True)
        subprocess.run(['sudo', 'ldconfig'], check=True)
        print_ok("已成功将 librknnrt.so 部署到 /usr/lib/")
        return True
    except subprocess.CalledProcessError:
        print_err("自动部署失败，请手动执行以下命令：")
        print_bold(f"  sudo cp {local_so} /usr/lib/ && sudo ldconfig")
        return False

def check_librknnrt():
    """检查 librknnrt.so 是否在系统库路径中"""
    for path in ['/usr/lib', '/usr/local/lib']:
        if os.path.exists(os.path.join(path, 'librknnrt.so')):
            return True
    try:
        res = subprocess.run(['ldconfig', '-p'], capture_output=True, text=True)
        if 'librknnrt.so' in res.stdout:
            return True
    except:
        pass
    return False

def guide_install_librknnrt():
    print_section("缺少 NPU 运行时库 (librknnrt.so)")
    print_bold("请按以下步骤安装：")
    print("1. 下载库文件：")
    print("   cd /tmp")
    print("   wget https://raw.githubusercontent.com/airockchip/rknn-toolkit2/master/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so")
    print("2. 安装：")
    print_bold("   sudo cp librknnrt.so /usr/lib/ && sudo ldconfig")
    print("\n若 wget 失败，也可从开发板预置目录或虚拟环境复制。")
    sys.exit(1)

# ================= python3-venv 检查 =================
def check_python_venv_installed(python_version=None):
    if python_version is None:
        python_version = f"{sys.version_info.major}.{sys.version_info.minor}"
    pkg = f"python{python_version}-venv"
    try:
        subprocess.run(['dpkg', '-s', pkg], capture_output=True, check=True)
        return True
    except:
        pass
    try:
        res = subprocess.run(
            ['bash', '-c', f'apt list --installed 2>/dev/null | grep -q "^{pkg}/"'],
            capture_output=True)
        if res.returncode == 0:
            return True
    except:
        pass
    return False

# ================= 虚拟环境处理 =================
POSSIBLE_VENVS = [
    "/home/seeed/rknpu_env",
    "/root/rknpu_env",
    os.path.expanduser("~/rknpu_env"),
    "/home/seeed/venv",
    "/root/venv",
]

def is_venv():
    return sys.prefix != sys.base_prefix

def find_venv_with_rknn():
    for venv_dir in POSSIBLE_VENVS:
        python_path = os.path.join(venv_dir, "bin", "python3")
        if os.path.isfile(python_path):
            try:
                res = subprocess.run([python_path, "-c", "from rknnlite.api import RKNNLite"],
                                     capture_output=True, timeout=5)
                if res.returncode == 0:
                    return python_path
            except:
                continue
    return None

def switch_to_venv(venv_python):
    print_bold(f"🔄 正在切换到虚拟环境: {venv_python}")
    os.execv(venv_python, [venv_python] + sys.argv)

def parse_cp_tag(cp_tag):
    match = re.search(r'cp(\d+)(?:m)?', cp_tag)
    if not match:
        return None
    digits = match.group(1)
    if len(digits) == 1:
        major, minor = digits, '0'
    elif len(digits) == 2:
        major, minor = digits[0], digits[1]
    else:
        major = digits[0]
        minor = digits[1:]
    return f"{major}.{minor}"

def show_available_whls(clone_dir):
    result = subprocess.run(f"find {clone_dir} -name 'rknn_toolkit_lite2*.whl'", shell=True,
                            capture_output=True, text=True)
    files = [f.strip() for f in result.stdout.splitlines() if f.strip()]
    cp_versions = set()
    if files:
        print_bold("仓库中可用的预编译包：")
        for f in files:
            basename = os.path.basename(f)
            print(f"  {basename}")
            m = re.search(r'cp(\d+(?:m)?)', basename)
            if m:
                ver = parse_cp_tag(m.group(0))
                if ver:
                    cp_versions.add(ver)
        return sorted(cp_versions, key=lambda v: tuple(map(int, v.split('.'))))
    else:
        print_warn("仓库中未找到任何 rknn-toolkit-lite2 的 wheel 包。")
        return []

def find_installed_compatible_python(versions):
    for ver in sorted(versions, key=lambda v: tuple(map(int, v.split('.'))), reverse=True):
        bin_name = f"python{ver}"
        if shutil.which(bin_name):
            return ver
    return None

def install_instructions_for_version(ver):
    python_bin = f"python{ver}"
    venv_path = f"/home/seeed/rknpu_env_py{ver.replace('.', '')}"
    print_bold(f"1. 安装 Python {ver} 及 venv：")
    print_bold(f"   sudo apt update && sudo apt install {python_bin} {python_bin}-venv")
    print_bold(f"2. 创建虚拟环境：")
    print_bold(f"   {python_bin} -m venv {venv_path}")
    print_bold(f"3. 激活虚拟环境：")
    print_bold(f"   source {venv_path}/bin/activate")
    print_bold(f"4. 重新运行本脚本（会自动安装 wheel 包）：")
    print_bold(f"   ./npu_test_suite.py")

def source_build_python_instructions():
    """源码编译 Python 3.10.15 指引（已验证可行）"""
    print_section("推荐方案：源码编译安装 Python 3.10.15")
    print_bold("此方法无需依赖系统软件源，安全可靠，适合 ARM64 开发板。")
    print()
    print_bold("1. 安装编译依赖：")
    print("   sudo apt update")
    print("   sudo apt install -y build-essential libssl-dev zlib1g-dev \\")
    print("     libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev wget")
    print_bold("2. 下载 Python 3.10.15 源码：")
    print("   cd /tmp")
    print("   wget https://www.python.org/ftp/python/3.10.15/Python-3.10.15.tar.xz")
    print_bold("3. 解压并编译安装（安装到 /usr/local/python3.10）：")
    print("   tar -xf Python-3.10.15.tar.xz")
    print("   cd Python-3.10.15")
    print("   ./configure --enable-optimizations --prefix=/usr/local/python3.10")
    print("   make -j$(nproc)")
    print("   sudo make install")
    print_bold("4. 创建虚拟环境并激活：")
    print("   /usr/local/python3.10/bin/python3.10 -m venv /home/seeed/rknpu_env_py310")
    print("   source /home/seeed/rknpu_env_py310/bin/activate")
    print_bold("5. 重新运行本测试脚本：")
    print("   ./npu_test_suite.py")
    print()
    print_info("若下载 python.org 速度慢，可使用国内镜像或从其他设备传输。")

def auto_install_rknn_wheel():
    print_section("自动安装 rknn-toolkit-lite2")
    if shutil.which('git') is None:
        print_err("系统未安装 git，无法自动克隆仓库")
        print_bold("请手动安装 git: sudo apt update && sudo apt install git")
        sys.exit(1)

    clone_dir = "/tmp/rknn-toolkit2_auto"
    if os.path.exists(clone_dir):
        print_info(f"目录 {clone_dir} 已存在，将直接使用")
    else:
        print_bold("正在从 GitHub 克隆 rknn-toolkit2 仓库...")
        try:
            subprocess.run(['git', 'clone', '--depth', '1',
                            'https://github.com/airockchip/rknn-toolkit2.git', clone_dir],
                           check=True)
        except subprocess.CalledProcessError:
            print_err("克隆仓库失败，请检查网络或手动下载 wheel 包")
            sys.exit(1)

    # 查找匹配当前 Python 的 wheel
    py_ver = f"cp{sys.version_info.major}{sys.version_info.minor}"
    find_cmd = f"find {clone_dir} -name 'rknn_toolkit_lite2*{py_ver}*.whl'"
    result = subprocess.run(find_cmd, shell=True, capture_output=True, text=True)
    whl_files = [f.strip() for f in result.stdout.splitlines() if f.strip()]

    if whl_files:
        whl_path = whl_files[0]
        print_ok(f"找到匹配包: {os.path.basename(whl_path)}")
        print_bold("正在安装...")
        try:
            subprocess.run([sys.executable, '-m', 'pip', 'install', whl_path], check=True)
            print_ok("安装成功！请重新运行本脚本以继续测试。")
            sys.exit(0)
        except subprocess.CalledProcessError:
            print_err("安装失败，请检查 pip 状态或尝试手动安装。")
            sys.exit(1)

    # 无匹配包
    print_err(f"未找到匹配 Python {sys.version_info.major}.{sys.version_info.minor} 的预编译包")
    versions_available = show_available_whls(clone_dir)
    if not versions_available:
        sys.exit(1)

    # 检查是否有已安装的兼容 Python
    installed_ver = find_installed_compatible_python(versions_available)
    if installed_ver:
        print_section("解决方案：使用已安装的兼容 Python 版本")
        print_bold(f"检测到您的系统已安装 Python {installed_ver}，可直接使用。")
        install_instructions_for_version(installed_ver)
        sys.exit(0)

    # 既无已安装兼容版本，则给出源码编译 Python 3.10 的方案
    source_build_python_instructions()
    sys.exit(1)

def handle_missing_rknn(venv_dir=None):
    print_warn("检测到缺少 rknn-toolkit-lite2")
    print_info(f"当前 Python 版本: {sys.version.split()[0]}")
    choice = input("是否自动从 GitHub 克隆仓库并尝试安装？[Y/n]: ").strip().lower()
    if choice in ('', 'y', 'yes'):
        if not is_venv():
            if venv_dir:
                print_bold(f"请先激活虚拟环境: source {venv_dir}/bin/activate")
            else:
                print_bold("请先创建并激活虚拟环境。")
            sys.exit(1)
        auto_install_rknn_wheel()
    else:
        print_bold("手动安装步骤：")
        print("1. 克隆仓库：")
        print("   git clone --depth 1 https://github.com/airockchip/rknn-toolkit2.git /tmp/rknn-toolkit2")
        print("2. 查找匹配的 wheel 包：")
        py_ver = f"cp{sys.version_info.major}{sys.version_info.minor}"
        print(f"   find /tmp/rknn-toolkit2 -name 'rknn_toolkit_lite2*{py_ver}*.whl'")
        print("3. 安装：")
        print("   pip install <查找到的 .whl 文件路径>")
        sys.exit(1)

def activate_venv():
    # 优先自动部署 librknnrt.so
    if not try_auto_deploy_librknnrt():
        guide_install_librknnrt()

    if is_venv():
        print_ok("已在虚拟环境中运行")
        return

    print_warn("当前不在虚拟环境，正在搜索已安装的环境...")
    venv_python = find_venv_with_rknn()
    if venv_python:
        switch_to_venv(venv_python)
        return

    existing_venv = None
    for venv_dir in POSSIBLE_VENVS:
        if os.path.isdir(venv_dir) and os.path.isfile(os.path.join(venv_dir, "bin", "python3")):
            existing_venv = venv_dir
            break

    if existing_venv:
        print_warn(f"虚拟环境目录 '{existing_venv}' 已存在，但未安装 rknn")
        print_bold(f"请先激活该环境: source {existing_venv}/bin/activate")
        sys.exit(1)
    else:
        print_section("未找到任何虚拟环境")
        python_ver = f"python{sys.version_info.major}.{sys.version_info.minor}-venv"
        if not check_python_venv_installed():
            print_err(f"系统缺少 {python_ver} 包")
            print_bold("请执行: sudo apt update && sudo apt install {0}".format(python_ver))
        print_bold("\n创建虚拟环境并安装依赖：")
        print_bold("  python3 -m venv /home/seeed/rknpu_env")
        print_bold("  source /home/seeed/rknpu_env/bin/activate")
        sys.exit(1)

def check_packages():
    try:
        from rknnlite.api import RKNNLite
        print_ok("rknn-toolkit-lite2 已安装")
    except ImportError:
        handle_missing_rknn()
    try:
        import cv2, numpy as np
        print_ok("opencv-python, numpy 已安装")
    except ImportError as e:
        print_err(f"缺少依赖包: {e}")
        print_bold("请执行: pip install opencv-python numpy")
        sys.exit(1)

# ================= 模型文件查找 =================
def find_model_file(model_path, extra_dirs=None):
    if os.path.exists(model_path):
        return os.path.abspath(model_path)
    search_dirs = [
        os.getcwd(),
        os.path.expanduser("~/test_tools-RK3588/yolov5"),
        os.path.expanduser("~/test_file_RK3588/npu_test"),
        "/home/seeed/test_tools-RK3588/yolov5",
        "/home/seeed/test_file_RK3588/npu_test",
        "/root/test_tools-RK3588/yolov5",
    ]
    if extra_dirs:
        search_dirs = list(extra_dirs) + search_dirs
    for d in search_dirs:
        candidate = os.path.join(d, model_path)
        if os.path.exists(candidate):
            return os.path.abspath(candidate)
    return None

# ================= CSI Overlay 检查 =================
CSI_OVERLAY_LINE = "overlays=recomputer-rk3588-devkit-cam0-rpi-v3 recomputer-rk3588-devkit-cam1-rpi-v3"
def check_csi_overlays():
    env_file = "/boot/armbianEnv.txt"
    if not os.path.exists(env_file):
        print_err(f"配置文件 {env_file} 不存在！")
        return False
    try:
        with open(env_file, 'r') as f:
            content = f.read()
    except Exception as e:
        print_err(f"读取 {env_file} 失败: {e}")
        return False
    for line in content.splitlines():
        if line.startswith('#') or not line.startswith("overlays="):
            continue
        overlays = line.split('=', 1)[1].strip().split()
        if 'recomputer-rk3588-devkit-cam0-rpi-v3' in overlays and \
           'recomputer-rk3588-devkit-cam1-rpi-v3' in overlays:
            print_ok("CSI Overlay 配置正确")
            return True
    print_err("CSI Overlay 未正确配置")
    print(f"   请在 {env_file} 中添加以下行：")
    print_bold(f"     {CSI_OVERLAY_LINE}")
    print("   然后执行: sudo sync && sudo reboot")
    return False

# ================= 测试函数（带诊断） =================
def run_quick_test():
    print_section("纯 NPU 推理测试 (MobileNet-v1)")
    model = "mobilenet_v1.rknn"
    path = find_model_file(model)
    if not path:
        print_err(f"找不到模型文件 {model}")
        return
    print(f"📦 模型: {path}")
    try:
        from rknnlite.api import RKNNLite
        import numpy as np
        rknn = RKNNLite()
        if rknn.load_rknn(path) != 0:
            print_err("模型加载失败")
            return
        rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_AUTO)
        img = np.random.rand(1, 224, 224, 3).astype(np.float32)
        for _ in range(10): rknn.inference([img])
        times = []
        for _ in range(100):
            start = time.perf_counter()
            rknn.inference([img])
            times.append(time.perf_counter() - start)
        avg_ms = np.mean(times) * 1000
        fps = 1000 / avg_ms
        print_bold(f"平均推理时间: {avg_ms:.3f} ms  (≈ {fps:.1f} FPS)")
        rknn.release()
    except Exception as e:
        print_err(f"推理异常: {e}")

def run_csi_classify():
    print_section("CSI 摄像头实时分类")
    if not check_csi_overlays():
        print_warn("CSI Overlay 未配置，无法进行摄像头测试")
        return
    devices = {0: '/dev/video22', 1: '/dev/video31'}
    print("请选择摄像头: 0 - CSI0 (/dev/video22)  1 - CSI1 (/dev/video31)")
    try:
        choice = int(input("输入编号: ").strip())
        if choice not in devices:
            raise ValueError
    except:
        print_err("无效输入，返回主菜单")
        return
    cam_dev = devices[choice]
    model = "mobilenet_v1.rknn"
    path = find_model_file(model)
    if not path:
        print_err(f"找不到模型文件 {model}")
        return
    print(f"📦 模型: {path}, 摄像头: {cam_dev}")
    import cv2, numpy as np
    from rknnlite.api import RKNNLite
    INPUT_SIZE = 224
    rknn = RKNNLite()
    if rknn.load_rknn(path) != 0:
        print_err("模型加载失败"); return
    if rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_0) != 0:
        print_err("NPU 初始化失败"); return
    def open_camera(dev):
        pipeline = (f"v4l2src device={dev} ! video/x-raw, format=NV12, width=640, height=480, framerate=30/1 ! "
                    "videoconvert ! video/x-raw, format=BGR ! appsink")
        cap = cv2.VideoCapture(pipeline, cv2.CAP_GSTREAMER)
        if cap.isOpened():
            print(f"📷 摄像头已打开 ({dev})"); return cap
        cap = cv2.VideoCapture(dev, cv2.CAP_V4L2)
        if cap.isOpened():
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            print(f"📷 摄像头已打开 ({dev})"); return cap
        return None
    cap = open_camera(cam_dev)
    if cap is None:
        print_err("摄像头打开失败"); return
    print("按 'q' 退出实时画面")
    fps, frame_count, start_time = 0, 0, time.time()
    infer_times = []
    try:
        while True:
            ret, frame = cap.read()
            if not ret: break
            img = cv2.resize(frame, (INPUT_SIZE, INPUT_SIZE))
            img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
            input_tensor = np.expand_dims(img, axis=0)
            t0 = time.time()
            outputs = rknn.inference([input_tensor])
            infer_ms = (time.time() - t0) * 1000
            infer_times.append(infer_ms)
            class_id = np.argmax(outputs[0])
            confidence = outputs[0].flatten()[class_id]
            cv2.putText(frame, f"Class {class_id}: {confidence:.2f}", (10,30), cv2.FONT_HERSHEY_SIMPLEX,1,(0,255,0),2)
            cv2.putText(frame, f"Infer: {infer_ms:.1f}ms  FPS:{fps:.1f}", (10,70), cv2.FONT_HERSHEY_SIMPLEX,0.7,(0,255,0),2)
            cv2.imshow('CSI + NPU', frame)
            frame_count += 1
            if frame_count >= 10:
                fps = frame_count / (time.time() - start_time)
                frame_count, start_time = 0, time.time()
            if cv2.waitKey(1) & 0xFF == ord('q'): break
    except KeyboardInterrupt: pass
    finally:
        cap.release(); cv2.destroyAllWindows(); rknn.release()
    if infer_times:
        print_bold(f"推理统计: 平均 {np.mean(infer_times):.2f}ms, 最小 {np.min(infer_times):.2f}ms, 最大 {np.max(infer_times):.2f}ms")
    else:
        print_warn("未采集到推理数据")

class Tee:
    def __init__(self, *files): self.files = files
    def write(self, obj):
        for f in self.files: f.write(obj); f.flush()
    def flush(self):
        for f in self.files: f.flush()

def npu_worker(proc_id, model_path, core_mode, stop_event, counter, total_counter, input_size):
    """增强版 worker，带诊断输出"""
    try:
        from rknnlite.api import RKNNLite
        import numpy as np
        print(f"[Worker {proc_id}] 启动...", flush=True)
        rknn = RKNNLite()
        ret = rknn.load_rknn(model_path)
        if ret != 0:
            print(f"[Worker {proc_id}] 模型加载失败，返回码: {ret}", flush=True)
            return
        print(f"[Worker {proc_id}] 模型加载成功", flush=True)
        if core_mode == 'explicit':
            mask = [RKNNLite.NPU_CORE_0, RKNNLite.NPU_CORE_1, RKNNLite.NPU_CORE_2][proc_id % 3]
        else:
            mask = RKNNLite.NPU_CORE_AUTO
        ret = rknn.init_runtime(core_mask=mask)
        if ret != 0:
            print(f"[Worker {proc_id}] NPU 初始化失败，返回码: {ret}", flush=True)
            return
        print(f"[Worker {proc_id}] NPU 就绪，开始推理", flush=True)
        data = np.random.rand(1, input_size, input_size, 3).astype(np.float32)
        for _ in range(10): rknn.inference([data])
        local = 0
        while not stop_event.is_set():
            try:
                rknn.inference([data]); local += 1
                if local % 100 == 0:
                    with counter.get_lock(): counter.value += 100
                    with total_counter.get_lock(): total_counter.value += 100
            except Exception as e:
                print(f"[Worker {proc_id}] 推理异常: {e}", flush=True)
                break
        rem = local % 100
        with counter.get_lock(): counter.value += rem
        with total_counter.get_lock(): total_counter.value += rem
        rknn.release()
        print(f"[Worker {proc_id}] 退出，总推理次数: {local}", flush=True)
    except Exception as e:
        print(f"[Worker {proc_id}] 严重错误: {e}", flush=True)

def read_npu_load():
    try:
        with open("/sys/kernel/debug/rknpu/load","r") as f: return f.readline().strip() + "%"
    except: return "N/A"

def run_stress_test():
    print_section("NPU 压力测试 (YOLOv5s)")
    model = "yolov5s_relu_rk3588.rknn"
    path = find_model_file(model)
    if not path:
        print_err(f"找不到模型文件 {model}")
        return
    print(f"📦 模型: {path}")
    procs = 8; core_mode = "auto"; duration = 0; input_size = 640
    log_dir = os.path.join(os.getcwd(), "log")
    os.makedirs(log_dir, exist_ok=True)
    log_fn = os.path.join(log_dir, f"npu_stress_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log")
    log_f = open(log_fn, 'w', encoding='utf-8')
    orig_stdout, orig_stderr = sys.stdout, sys.stderr
    sys.stdout = Tee(orig_stdout, log_f)
    sys.stderr = Tee(orig_stderr, log_f)
    print(f"📄 日志: {log_fn}")
    print(f"⚙️  进程数: {procs} | 核心模式: {core_mode} | 时长: {'无限' if duration==0 else f'{duration}s'}")
    counters = [Value(c_ulonglong, 0) for _ in range(procs)]
    total = Value(c_ulonglong, 0)
    stop_ev = Event()
    workers = []
    for i in range(procs):
        p = Process(target=npu_worker, args=(i, path, core_mode, stop_ev, counters[i], total, input_size))
        p.daemon = True; p.start(); workers.append(p)
    test_start = time.time()
    try:
        print("\n📊 每秒统计 (Ctrl+C 停止)：")
        while not stop_ev.is_set():
            time.sleep(1)
            load = read_npu_load()
            print(f"  [{time.strftime('%H:%M:%S')}] 总推理: {total.value:>8d} | NPU 负载: {load}")
            if duration and time.time() - test_start >= duration:
                print("\n⏰ 达到设定时长，停止..."); break
    except KeyboardInterrupt:
        print("\n🛑 用户中断")
    finally:
        elapsed = time.time() - test_start
        final_total = total.value
        stop_ev.set()
        for p in workers: p.join(timeout=2)
        sys.stdout, sys.stderr = orig_stdout, orig_stderr
        log_f.close()
        print_ok("压力测试结束")
        print_bold(f"日志: {log_fn}")
        h, m, s = int(elapsed//3600), int((elapsed%3600)//60), int(elapsed%60)
        print_bold(f"总推理次数: {final_total}  测试时长: {h:02d}:{m:02d}:{s:02d}")

# ================= 主菜单 =================
def main():
    print_section("RK3588 NPU 环境检查")
    activate_venv()
    check_packages()
    while True:
        print(f"\n{BOLD}{'='*55}{NC}")
        print(f"{BOLD}  RK3588 NPU 测试工具{NC}")
        print(f"{BOLD}{'='*55}{NC}")
        print("  1. 纯 NPU 推理测试 (MobileNet-v1)")
        print("  2. CSI 摄像头实时分类")
        print("  3. NPU 压力测试 (YOLOv5s)")
        print("  q. 退出")
        choice = input("请选择: ").strip().lower()
        if choice == '1':
            run_quick_test()
        elif choice == '2':
            run_csi_classify()
        elif choice == '3':
            run_stress_test()
        elif choice == 'q':
            print("再见！")
            break
        else:
            print_err("无效输入，请重试")

if __name__ == '__main__':
    main()
