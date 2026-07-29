#!/usr/bin/env python3
"""
RK3588 NPU 综合测试工具（增强环境检查版 - 包含 .so 当前目录检测）
功能：
  1. 纯 NPU 推理测试 (MobileNet-v1) → 输出平均推理时间与 FPS
  2. CSI 摄像头实时分类 (可选 /dev/video22 或 /dev/video31)
  3. NPU 压力测试 (YOLOv5s, 多进程) → 输出日志文件路径、推理次数和测试时长
所有测试前自动检查虚拟环境和依赖包，缺失时给出修复指导。
新增：优先检查当前目录下的 librknnrt.so，若无则在线下载指引。
"""

import os, sys, time, signal, argparse, subprocess, multiprocessing, re
from multiprocessing import Process, Value, Event
from ctypes import c_ulonglong
from datetime import datetime

# ================= 动态库检查（完整实现，增加当前目录检测） =================
def check_librknnrt():
    """检查 librknnrt.so 是否在系统库路径、虚拟环境或当前目录中"""
    # 1. 当前工作目录（脚本所在目录通常为运行目录）
    if os.path.exists(os.path.join(os.getcwd(), 'librknnrt.so')):
        return True

    # 2. 系统库路径
    search_paths = [
        '/usr/lib', '/usr/local/lib',
        '/home/seeed/rknpu_env/lib',  # 虚拟环境库路径
    ]
    for path in search_paths:
        if os.path.exists(os.path.join(path, 'librknnrt.so')):
            return True

    # 3. ldconfig 缓存
    try:
        result = subprocess.run(['ldconfig', '-p'], capture_output=True, text=True)
        if 'librknnrt.so' in result.stdout:
            return True
    except:
        pass
    return False

def guide_install_librknnrt():
    """打印动态库安装指南（智能判断当前目录是否已有 .so）"""
    print("=" * 50)
    print("❌ 缺少 NPU 运行时库 (librknnrt.so)")
    print("=" * 50)

    # 检查当前目录是否恰好存在该文件（可能是用户忘记复制到系统路径）
    local_so = os.path.join(os.getcwd(), 'librknnrt.so')
    if os.path.exists(local_so):
        print("ℹ️  检测到当前目录下存在 librknnrt.so，您只需将其复制到系统库路径即可：")
        print("  sudo cp librknnrt.so /usr/lib/")
        print("  sudo ldconfig")
        print("  （或复制到 /usr/local/lib 亦可）")
        print("=" * 50)
        sys.exit(1)

    # 如果没有本地文件，则指引下载
    print("请按以下步骤安装：")
    print("")
    print("【在线安装（推荐）】")
    print("  cd /tmp")
    print("  wget https://raw.githubusercontent.com/airockchip/rknn-toolkit2/master/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so")
    print("  sudo cp librknnrt.so /usr/lib/")
    print("  sudo ldconfig")
    print("")
    print("【离线安装（从虚拟环境复制）】")
    print("  如果虚拟环境中已安装 rknn-toolkit-lite2，可以手动复制：")
    print("  find /home/seeed/rknpu_env -name 'librknnrt.so'")
    print("  然后 sudo cp <路径> /usr/lib/ && sudo ldconfig")
    print("=" * 50)
    sys.exit(1)

# ================= 检查 python3-venv 包 =================
def check_python_venv_installed():
    """返回 True 如果系统已安装与当前 Python 版本对应的 venv 包"""
    python_ver = f"python{sys.version_info.major}.{sys.version_info.minor}-venv"
    try:
        result = subprocess.run(['dpkg', '-s', python_ver],
                                capture_output=True, text=True)
        if result.returncode == 0:
            return True
    except:
        pass
    try:
        result = subprocess.run(
            ['bash', '-c', f'apt list --installed 2>/dev/null | grep -q "^{python_ver}/"'],
            capture_output=True, text=True)
        if result.returncode == 0:
            return True
    except:
        pass
    return False

# ================= 环境自检与切换 =================
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
    print(f"🔄 正在使用虚拟环境: {venv_python}")
    os.execv(venv_python, [venv_python] + sys.argv)

def activate_venv():
    if not check_librknnrt():
        guide_install_librknnrt()
    if is_venv():
        print("✅ 已在虚拟环境中运行")
        return
    print("⚠️ 当前未在虚拟环境中，正在搜索已安装的虚拟环境...")
    venv_python = find_venv_with_rknn()
    if venv_python:
        switch_to_venv(venv_python)
    else:
        print("❌ 未找到包含 rknn-toolkit-lite2 的虚拟环境。")
        if not check_python_venv_installed():
            python_ver = f"python{sys.version_info.major}.{sys.version_info.minor}-venv"
            print(f"⚠️  系统尚未安装 {python_ver} 包，无法创建虚拟环境。")
            print(f"请先执行：sudo apt install {python_ver}")
            print("安装完成后，再执行以下步骤创建虚拟环境。")
        print("请创建虚拟环境并安装依赖：")
        print("  python3 -m venv /home/seeed/rknpu_env")
        print("  source /home/seeed/rknpu_env/bin/activate")
        print("  pip install rknn-toolkit-lite2 numpy opencv-python")
        sys.exit(1)

def check_packages():
    try:
        from rknnlite.api import RKNNLite
        print("✅ rknn-toolkit-lite2 已安装")
    except ImportError:
        print("❌ 缺少 rknn-toolkit-lite2，请安装：")
        print("  pip install rknn-toolkit-lite2")
        sys.exit(1)
    try:
        import cv2
        import numpy as np
        print("✅ opencv-python, numpy 已安装")
    except ImportError as e:
        print(f"❌ 缺少依赖包: {e}")
        print("  pip install opencv-python numpy")
        sys.exit(1)

def find_model_file(model_path, additional_dirs=None):
    if os.path.exists(model_path):
        return os.path.abspath(model_path)
    search_dirs = [
        os.getcwd(),
        os.path.join(os.path.expanduser("~"), "test_tools-RK3588/yolov5"),
        os.path.join(os.path.expanduser("~"), "test_file_RK3588/npu_test"),
        "/home/seeed/test_tools-RK3588/yolov5",
        "/home/seeed/test_file_RK3588/npu_test",
        "/root/test_tools-RK3588/yolov5",
    ]
    if additional_dirs:
        search_dirs = list(additional_dirs) + search_dirs
    for d in search_dirs:
        candidate = os.path.join(d, model_path) if not os.path.isabs(model_path) else model_path
        if os.path.exists(candidate):
            return os.path.abspath(candidate)
    return None

# ================= CSI Overlay 检查 =================
CSI_OVERLAY_LINE = "overlays=recomputer-rk3588-devkit-cam0-rpi-v3 recomputer-rk3588-devkit-cam1-rpi-v3"

def check_csi_overlays():
    env_file = "/boot/armbianEnv.txt"
    if not os.path.exists(env_file):
        print(f"❌ 配置文件 {env_file} 不存在！")
        return False
    try:
        with open(env_file, 'r') as f:
            content = f.read()
    except Exception as e:
        print(f"❌ 读取 {env_file} 失败: {e}")
        return False
    pattern = r'^overlays=(.*)$'
    for line in content.splitlines():
        line = line.strip()
        if line.startswith('#'):
            continue
        m = re.match(pattern, line, re.IGNORECASE)
        if m:
            overlays = m.group(1).strip().split()
            if 'recomputer-rk3588-devkit-cam0-rpi-v3' in overlays and \
               'recomputer-rk3588-devkit-cam1-rpi-v3' in overlays:
                print("✅ CSI Overlay 配置已正确设置")
                return True
    print("❌ 未找到正确的 CSI Overlay 配置。")
    print(f"   请在 {env_file} 中添加或修改为以下行：")
    print(f"   {CSI_OVERLAY_LINE}")
    print("   （如果已有其他 overlay，用空格分隔）")
    print("   然后执行：")
    print("     sudo sync")
    print("     sudo reboot")
    print("   重启后 CSI 摄像头才能正常工作。")
    return False

# ================= 测试结果报告 =================
def print_separator():
    print("-" * 50)

def report_result(test_name, success, details=""):
    status = "✅ 成功" if success else "❌ 失败"
    print(f"\n📊 [{test_name}] 测试结果: {status}")
    if details:
        print(details)
    print_separator()

# ================= 1. 纯 NPU 推理测试 =================
def run_quick_test():
    test_name = "纯 NPU 推理测试 (MobileNet-v1)"
    model = "mobilenet_v1.rknn"
    path = find_model_file(model)
    if not path:
        print(f"❌ 找不到模型文件 {model}")
        report_result(test_name, False)
        return
    print(f"📦 使用模型: {path}")
    try:
        from rknnlite.api import RKNNLite
        import numpy as np
        rknn = RKNNLite()
        if rknn.load_rknn(path) != 0:
            print("模型加载失败")
            report_result(test_name, False)
            return
        rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_AUTO)
        img = np.random.rand(1, 224, 224, 3).astype(np.float32)
        for _ in range(10):
            rknn.inference([img])
        times = []
        for _ in range(100):
            start = time.perf_counter()
            rknn.inference([img])
            times.append(time.perf_counter() - start)
        avg_ms = np.mean(times) * 1000
        fps = 1000 / avg_ms
        print(f"MobileNet-v1 平均推理时间: {avg_ms:.3f} ms  (≈ {fps:.1f} FPS)")
        report_result(test_name, True, f"平均推理时间: {avg_ms:.3f} ms, FPS: {fps:.1f}")
        rknn.release()
    except Exception as e:
        print(f"推理测试异常: {e}")
        report_result(test_name, False)

# ================= 2. CSI 摄像头实时分类 =================
def run_csi_classify():
    test_name = "CSI 摄像头实时分类"
    if not check_csi_overlays():
        print("⚠️  CSI Overlay 配置错误，无法进行摄像头测试。")
        report_result(test_name, False, "CSI Overlay 未配置或配置错误")
        return

    devices = {0: '/dev/video22', 1: '/dev/video31'}
    print("请选择摄像头:")
    print("  0 - CSI0 (/dev/video22)")
    print("  1 - CSI1 (/dev/video31)")
    try:
        choice = int(input("请输入编号 (0 或 1): ").strip())
        if choice not in devices:
            raise ValueError
    except:
        print("❌ 输入无效，返回主菜单")
        report_result(test_name, False, "用户输入无效")
        return
    cam_dev = devices[choice]

    model = "mobilenet_v1.rknn"
    path = find_model_file(model)
    if not path:
        print(f"❌ 找不到模型文件 {model}")
        report_result(test_name, False)
        return
    print(f"📦 使用模型: {path}, 摄像头: {cam_dev}")

    import cv2
    import numpy as np
    from rknnlite.api import RKNNLite

    INPUT_SIZE = 224
    rknn = RKNNLite()
    if rknn.load_rknn(path) != 0:
        print("模型加载失败")
        report_result(test_name, False)
        return
    ret = rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_0)
    if ret != 0:
        print("NPU 初始化失败")
        report_result(test_name, False)
        return

    def open_camera(dev):
        pipeline = (f"v4l2src device={dev} ! "
                    "video/x-raw, format=NV12, width=640, height=480, framerate=30/1 ! "
                    "videoconvert ! video/x-raw, format=BGR ! appsink")
        cap = cv2.VideoCapture(pipeline, cv2.CAP_GSTREAMER)
        if cap.isOpened():
            print(f"摄像头已打开: {dev} (GStreamer)")
            return cap
        cap = cv2.VideoCapture(dev, cv2.CAP_V4L2)
        if cap.isOpened():
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            print(f"摄像头已打开: {dev} (V4L2 MJPG)")
            return cap
        return None

    cap = open_camera(cam_dev)
    if cap is None:
        print("摄像头打开失败")
        report_result(test_name, False)
        return

    print("按 'q' 键退出实时分类")
    fps = 0; frame_count = 0; start_time = time.time()
    infer_times = []
    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                print("读取帧失败")
                break
            img = cv2.resize(frame, (INPUT_SIZE, INPUT_SIZE))
            img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
            img = img.astype(np.float32) / 255.0
            input_tensor = np.expand_dims(img, axis=0)

            t0 = time.time()
            outputs = rknn.inference([input_tensor])
            infer_ms = (time.time() - t0) * 1000
            infer_times.append(infer_ms)

            scores = outputs[0].flatten()
            class_id = np.argmax(scores)
            confidence = scores[class_id]

            label = f"Class {class_id}: {confidence:.2f}"
            cv2.putText(frame, label, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1, (0,255,0), 2)
            cv2.putText(frame, f"Infer: {infer_ms:.1f}ms", (10, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0,255,0), 2)
            cv2.putText(frame, f"FPS: {fps:.1f}", (10, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0,255,0), 2)
            cv2.imshow('CSI + NPU', frame)

            frame_count += 1
            if frame_count >= 10:
                end_time = time.time()
                fps = frame_count / (end_time - start_time)
                frame_count = 0; start_time = end_time
            if cv2.waitKey(1) & 0xFF == ord('q'):
                break
    except KeyboardInterrupt:
        pass
    finally:
        cap.release()
        cv2.destroyAllWindows()
        rknn.release()

    if infer_times:
        avg_infer = np.mean(infer_times)
        min_infer = np.min(infer_times)
        max_infer = np.max(infer_times)
        detail = (f"推理样本数: {len(infer_times)}\n"
                  f"平均推理时间: {avg_infer:.2f} ms, 最小: {min_infer:.2f} ms, 最大: {max_infer:.2f} ms\n"
                  f"最终显示 FPS: {fps:.1f}")
        report_result(test_name, True, detail)
    else:
        report_result(test_name, False, "未采集到推理数据")

# ================= 3. NPU 压力测试 =================
class Tee:
    def __init__(self, *files):
        self.files = files
    def write(self, obj):
        for f in self.files:
            f.write(obj); f.flush()
    def flush(self):
        for f in self.files: f.flush()

def npu_worker(proc_id, model_path, core_mode, stop_event, counter, total_counter, input_size):
    from rknnlite.api import RKNNLite
    import numpy as np
    rknn = RKNNLite()
    if rknn.load_rknn(model_path) != 0:
        print(f"[Worker {proc_id}] 模型加载失败")
        return
    if core_mode == 'explicit':
        masks = [RKNNLite.NPU_CORE_0, RKNNLite.NPU_CORE_1, RKNNLite.NPU_CORE_2]
        core_mask = masks[proc_id % 3]
    else:
        core_mask = RKNNLite.NPU_CORE_AUTO
    if rknn.init_runtime(core_mask=core_mask) != 0:
        print(f"[Worker {proc_id}] NPU 初始化失败")
        return
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
            print(f"[Worker {proc_id}] 推理错误: {e}"); break
    rem = local % 100
    with counter.get_lock(): counter.value += rem
    with total_counter.get_lock(): total_counter.value += rem
    rknn.release()

def read_npu_load():
    try:
        with open("/sys/kernel/debug/rknpu/load","r") as f: return f.readline().strip()
    except: return "N/A"

def run_stress_test():
    test_name = "NPU 压力测试 (YOLOv5s)"
    model = "yolov5s_relu_rk3588.rknn"
    path = find_model_file(model)
    if not path:
        print(f"❌ 找不到模型文件 {model}")
        report_result(test_name, False)
        return
    print(f"📦 使用模型: {path}")
    procs = 8
    core_mode = "auto"
    duration = 0
    input_size = 640

    log_dir = os.path.join(os.getcwd(), "log")
    os.makedirs(log_dir, exist_ok=True)
    log_fn = os.path.join(log_dir, f"npu_stress_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log")
    log_f = open(log_fn, 'w', encoding='utf-8')
    orig_stdout, orig_stderr = sys.stdout, sys.stderr
    sys.stdout = Tee(orig_stdout, log_f)
    sys.stderr = Tee(orig_stderr, log_f)

    print(f"📄 日志文件: {log_fn}")
    print(f"⚙️  并发进程: {procs}, 核心模式: {core_mode}, 时长: {'无限' if duration==0 else f'{duration}s'}")
    counters = [Value(c_ulonglong, 0) for _ in range(procs)]
    total = Value(c_ulonglong, 0)
    stop_ev = Event()
    procs_list = []
    for i in range(procs):
        p = Process(target=npu_worker, args=(i, path, core_mode, stop_ev, counters[i], total, input_size))
        p.daemon = True; p.start()
        procs_list.append(p)
        print(f"  ✅ Worker {i} PID={p.pid}")

    test_start = time.time()
    final_total = 0
    try:
        print("\n📊 每秒推理统计 (Ctrl+C 停止)：")
        while not stop_ev.is_set():
            time.sleep(1)
            t = total.value
            load = read_npu_load()
            print(f"[{time.strftime('%H:%M:%S')}] 总推理: {t:>10d} | NPU 负载: {load}")
            if duration and time.time() >= test_start + duration:
                print("\n⏰ 达到设定时长，停止..."); break
    except KeyboardInterrupt:
        print("\n🛑 用户中断")
    finally:
        test_end = time.time()
        elapsed = test_end - test_start
        final_total = total.value
        stop_ev.set()
        for p in procs_list: p.join(timeout=2)
        sys.stdout = orig_stdout; sys.stderr = orig_stderr; log_f.close()
        print("✅ 压力测试结束")
        print(f"📄 日志已保存至: {log_fn}")
        hours = int(elapsed // 3600)
        minutes = int((elapsed % 3600) // 60)
        seconds = int(elapsed % 60)
        time_str = f"{hours:02d}:{minutes:02d}:{seconds:02d}"
        detail = f"最终推理次数: {final_total}\n测试时长: {time_str} (H:M:S)\n日志文件: {log_fn}"
        report_result(test_name, True, detail)

# ================= 主菜单 =================
def main():
    print("=" * 50)
    print("环境检查")
    print("=" * 50)
    activate_venv()
    check_packages()

    while True:
        print("\n" + "=" * 50)
        print("RK3588 NPU 综合测试工具")
        print("=" * 50)
        print("1. 纯 NPU 推理测试 (MobileNet-v1)")
        print("2. CSI 摄像头实时分类")
        print("3. NPU 压力测试 (YOLOv5s)")
        print("q. 退出")
        choice = input("请选择: ").strip()
        if choice == '1':
            run_quick_test()
        elif choice == '2':
            run_csi_classify()
        elif choice == '3':
            run_stress_test()
        elif choice.lower() == 'q':
            print("再见！")
            break
        else:
            print("❌ 无效输入，请重新选择")

if __name__ == '__main__':
    main()
