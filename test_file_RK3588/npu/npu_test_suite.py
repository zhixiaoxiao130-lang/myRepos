#!/usr/bin/env python3
"""
RK3588 NPU 综合测试工具（最终版 - 权限修复、健康检查、自动安装）
功能：
  1. 纯 NPU 推理测试 (MobileNet-v1)
  2. CSI 摄像头实时分类
  3. NPU 压力测试 (YOLOv5s)
环境自检：
  - 自动部署 librknnrt.so（若当前目录存在）
  - 优先搜索本地 rknn_toolkit_lite2*.whl 并安装（失败不退出）
  - 自动搜索并激活已存在的虚拟环境（向上遍历父目录 + 常用路径）
  - 发现权限问题时提示 chmod +x；健康检查解释器，损坏时引导重新编译
  - 缺失包时询问自动安装（opencv-python/numpy）
  - 未找到虚拟环境时智能分析 wheel 包或直接指导源码编译（不再推荐 python3.13-venv）
"""

import os, sys, time, subprocess, multiprocessing, re, shutil, glob
from multiprocessing import Process, Value, Event
from datetime import datetime

# 尝试导入 ctypes，若失败则说明 Python 编译不完整，给出明确修复指导
try:
    from ctypes import c_ulonglong
except ImportError:
    RED = '\033[91m'
    BOLD = '\033[1m'
    NC = '\033[0m'
    print(f"{RED}❌ 当前 Python 环境缺少 '_ctypes' 模块（编译时未安装 libffi-dev）。{NC}")
    print(f"{BOLD}请执行以下命令修复：{NC}")
    print(f"{BOLD}  sudo apt update && sudo apt install -y libffi-dev{NC}")
    print(f"{BOLD}  然后重新编译 Python 3.10.15 并创建虚拟环境。{NC}")
    sys.exit(1)

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
def check_librknnrt():
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

def try_auto_deploy_librknnrt():
    if check_librknnrt():
        return True
    local_so = os.path.join(os.getcwd(), 'librknnrt.so')
    if not os.path.exists(local_so):
        return False
    print_warn("当前目录存在 librknnrt.so，但系统库路径中未找到，尝试自动部署...")
    try:
        subprocess.run(['sudo', 'cp', local_so, '/usr/lib/'], check=True)
        subprocess.run(['sudo', 'ldconfig'], check=True)
        print_ok("已成功将 librknnrt.so 部署到 /usr/lib/")
        return True
    except subprocess.CalledProcessError:
        print_err("自动部署失败，请手动执行：")
        print_bold(f"  sudo cp {local_so} /usr/lib/ && sudo ldconfig")
        return False

def guide_install_librknnrt():
    print_section("缺少 NPU 运行时库 (librknnrt.so)")
    print_bold("请按以下步骤安装：")
    print("1. 下载库文件：")
    print("   cd /tmp")
    print("   wget https://raw.githubusercontent.com/airockchip/rknn-toolkit2/master/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so")
    print("2. 安装：")
    print_bold("   sudo cp librknnrt.so /usr/lib/ && sudo ldconfig")
    sys.exit(1)

# ================= 本地 wheel 安装（失败不退出） =================
def try_install_local_wheel():
    wheel_files = glob.glob("rknn_toolkit_lite2*.whl")
    if not wheel_files:
        return False
    whl = wheel_files[0]
    print_ok(f"发现本地 wheel 包: {whl}")
    print_bold("正在安装，请稍候...")
    try:
        subprocess.run([sys.executable, '-m', 'pip', 'install', whl], check=True)
        print_ok("安装成功！请重新运行本脚本以继续测试。")
        sys.exit(0)
    except subprocess.CalledProcessError:
        print_err("本地 wheel 包安装失败（Python 版本不匹配或缺少依赖）。")
        print_info("脚本将尝试其他安装方式...")
        return False

# ================= 虚拟环境智能发现 =================
POSSIBLE_VENVS = [
    "/home/seeed/rknpu_env",
    "/home/seeed/rknpu_env_py310",
    "/home/seeed/rknpu_env_py311",
    "/home/seeed/rknpu_env_py312",
    "/home/seeed/test_file_RK3588/rknpu_env_py310",
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
    print_bold(f"🔄 正在自动进入虚拟环境: {venv_python}")
    os.execv(venv_python, [venv_python] + sys.argv)

def check_python_health(python_bin):
    """检查指定 Python 解释器是否可正常运行（导入 ctypes）"""
    try:
        result = subprocess.run(
            [python_bin, '-c', 'import ctypes; print("ok")'],
            capture_output=True, text=True, timeout=5
        )
        return result.returncode == 0 and 'ok' in result.stdout
    except Exception:
        return False

def is_python310_installed():
    """检测系统是否已安装 Python 3.10"""
    # 检查常见的 python3.10 路径
    for path in ['/usr/local/python3.10/bin/python3.10', '/usr/bin/python3.10']:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return True
    # 检查 PATH 中是否有 python3.10
    if shutil.which('python3.10'):
        return True
    return False

def is_python_binary_real(python_bin):
    """检查 Python 解释器是否真实存在（不是损坏的软链接）"""
    try:
        real_path = os.path.realpath(python_bin)
        return os.path.isfile(real_path) and os.access(real_path, os.X_OK)
    except Exception:
        return False

def handle_venv_python_broken(python_bin):
    """当虚拟环境中的 Python 解释器不可用时，给出正确的修复指引"""
    print_section("虚拟环境中的 Python 解释器无法运行")
    print_warn(f"解释器 '{python_bin}' 存在，但无法正确执行 Python 代码。")

    if not is_python_binary_real(python_bin):
        # 软链接指向的 Python 二进制文件不存在
        print_info("该解释器是一个损坏的软链接，指向的 Python 二进制文件不存在。")
        if is_python310_installed():
            # Python 3.10 已安装，只需重建虚拟环境
            print_info("但系统已安装 Python 3.10，只需重建虚拟环境即可。")
            venv_dir = os.path.dirname(os.path.dirname(python_bin))
            print_bold("请执行以下命令重建虚拟环境：")
            print_bold(f"  rm -rf {venv_dir}")
            print_bold(f"  /usr/local/python3.10/bin/python3.10 -m venv {venv_dir}")
            print_bold("然后重新运行本脚本。")
        else:
            print_info("这表明 Python 3.10 未被正确安装或已被移除。")
            source_build_python_instructions()
        sys.exit(1)

    if is_python310_installed():
        # Python 3.10 已安装但缺少 _ctypes 模块
        print_info("Python 3.10 已安装，但缺少 _ctypes 模块（通常是因为编译时未安装 libffi-dev）。")
        print_bold("请重新编译 Python 3.10.15（确保安装 libffi-dev）：")
        print_bold("  sudo apt update && sudo apt install -y libffi-dev")
        print_bold("  cd /tmp/Python-3.10.15")
        print_bold("  ./configure --enable-optimizations --prefix=/usr/local/python3.10")
        print_bold("  make -j$(nproc) && sudo make install")
        print_bold("  rm -rf /home/seeed/test_file_RK3588/rknpu_env_py310")
        print_bold("  /usr/local/python3.10/bin/python3.10 -m venv /home/seeed/test_file_RK3588/rknpu_env_py310")
        print_bold("然后重新运行本脚本。")
    else:
        # Python 3.10 未安装，需要完整安装
        print_info("系统未安装 Python 3.10，需要完整安装。")
        source_build_python_instructions()
    sys.exit(1)

def scan_extra_venvs():
    extra = []
    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
    except:
        script_dir = os.getcwd()
    current = script_dir
    while True:
        try:
            if os.path.isdir(current):
                for name in os.listdir(current):
                    if name.startswith('rknpu_env'):
                        path = os.path.join(current, name)
                        if os.path.isdir(path) and path not in extra:
                            extra.append(path)
        except (PermissionError, OSError):
            pass
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    home = os.path.expanduser("~")
    try:
        if os.path.isdir(home):
            for name in os.listdir(home):
                if name.startswith('rknpu_env'):
                    path = os.path.join(home, name)
                    if os.path.isdir(path) and path not in extra:
                        extra.append(path)
    except (PermissionError, OSError):
        pass
    for alt in ["/home/seeed/test_file_RK3588/rknpu_env_py310",
                "/home/seeed/rknpu_env_py310"]:
        if os.path.isdir(alt) and alt not in extra:
            extra.append(alt)
    return extra

def find_first_valid_venv(venv_dirs):
    for venv_dir in venv_dirs:
        python_bin = os.path.join(venv_dir, "bin", "python3")
        if os.path.isfile(python_bin) and os.access(python_bin, os.X_OK):
            return python_bin
    return None

def activate_venv():
    if not try_auto_deploy_librknnrt():
        guide_install_librknnrt()

    if is_venv():
        print_ok("已在虚拟环境中运行")
        return

    print_warn("当前不在虚拟环境，正在搜索已安装的环境...")
    # 1. 优先查找已安装 rknn 的环境
    venv_python = find_venv_with_rknn()
    if venv_python:
        if check_python_health(venv_python):
            switch_to_venv(venv_python)
        else:
            handle_venv_python_broken(venv_python)

    # 2. 查找任意有效虚拟环境
    all_venv_dirs = list(dict.fromkeys(POSSIBLE_VENVS + scan_extra_venvs()))
    python_bin = find_first_valid_venv(all_venv_dirs)
    if python_bin:
        if check_python_health(python_bin):
            venv_dir = os.path.dirname(os.path.dirname(python_bin))
            print_warn(f"找到虚拟环境 '{venv_dir}'，正在自动激活...")
            switch_to_venv(python_bin)
        else:
            handle_venv_python_broken(python_bin)

    # 3. 检查是否存在 python3 文件但缺少执行权限
    for venv_dir in all_venv_dirs:
        py_path = os.path.join(venv_dir, "bin", "python3")
        if os.path.isfile(py_path):
            if not is_python_binary_real(py_path):
                if is_python310_installed():
                    # Python 3.10 已安装，只需重建虚拟环境
                    print_info(f"文件 '{py_path}' 存在，但其指向的 Python 二进制文件不存在。")
                    print_info("但系统已安装 Python 3.10，只需重建虚拟环境即可。")
                    print_bold("请执行以下命令重建虚拟环境：")
                    print_bold(f"  rm -rf {venv_dir}")
                    print_bold(f"  /usr/local/python3.10/bin/python3.10 -m venv {venv_dir}")
                    print_bold("然后重新运行本脚本。")
                else:
                    print_info(f"文件 '{py_path}' 存在，但其指向的 Python 二进制文件不存在。")
                    print_info("这表明 Python 3.10 未被正确安装或已被移除。")
                    source_build_python_instructions()
                sys.exit(1)
            print_section("虚拟环境已存在但 Python 无执行权限")
            print_warn(f"文件 '{py_path}' 存在，但缺少可执行权限。")
            print_bold("请执行以下命令修复权限：")
            print_bold(f"  chmod +x {py_path}")
            print_bold("修复后重新运行本脚本。")
            sys.exit(1)

    # 4. 没有任何可用的虚拟环境
    print_section("未找到兼容的虚拟环境")
    wheel_files = glob.glob("rknn_toolkit_lite2*.whl")
    if wheel_files:
        cp_match = re.search(r'cp(\d+)', wheel_files[0])
        if cp_match:
            required_ver = parse_cp_tag(cp_match.group(0))
            if required_ver:
                python_bin = f"python{required_ver}"
                if shutil.which(python_bin) or (required_ver == "3.10" and is_python310_installed()):
                    print_bold(f"检测到系统已安装 Python {required_ver}，请创建虚拟环境：")
                    venv_name = f"rknpu_env_py{required_ver.replace('.', '')}"
                    # 如果 python3.10 不在 PATH，使用完整路径
                    cmd = python_bin if shutil.which(python_bin) else "/usr/local/python3.10/bin/python3.10"
                    print_bold(f"  {cmd} -m venv /home/seeed/{venv_name}")
                    print_bold(f"  source /home/seeed/{venv_name}/bin/activate")
                    print_bold("然后重新运行本脚本。")
                else:
                    print_bold(f"本地 wheel 包需要 Python {required_ver}，但系统未安装。")
                    source_build_python_instructions()
                sys.exit(1)
    # 通用方案：检查 Python 3.10 是否已安装
    if is_python310_installed():
        print_bold("系统已安装 Python 3.10，只需创建虚拟环境即可：")
        print_bold("  /usr/local/python3.10/bin/python3.10 -m venv /home/seeed/rknpu_env_py310")
        print_bold("  source /home/seeed/rknpu_env_py310/bin/activate")
        print_bold("然后重新运行本脚本。")
    else:
        print_bold("建议源码编译安装 Python 3.10.15（已适配 RK3588）。")
        source_build_python_instructions()
    sys.exit(1)

# ================= RKNN wheel 安装相关 =================
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

def source_build_python_instructions():
    print_section("源码编译安装 Python 3.10.15（推荐）")
    print_bold("此方法无需依赖系统软件源，安全可靠，适合 ARM64 开发板。")
    print()
    print_bold("1. 安装编译依赖（确保 libffi-dev 已安装）：")
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
    print_bold("4. 激活已有虚拟环境（如已存在）或创建新环境：")
    print("   如果您已有 rknpu_env_py310 目录，直接激活即可：")
    print_bold("     source /home/seeed/test_file_RK3588/rknpu_env_py310/bin/activate")
    print("   如需新建，请执行：")
    print_bold("     /usr/local/python3.10/bin/python3.10 -m venv /home/seeed/rknpu_env_py310")
    print_bold("     source /home/seeed/rknpu_env_py310/bin/activate")
    print_bold("5. 重新运行本测试脚本：")
    print("   ./npu_test_suite.py")
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

    print_err(f"未找到匹配 Python {sys.version_info.major}.{sys.version_info.minor} 的预编译包")
    versions_available = show_available_whls(clone_dir)
    if not versions_available:
        sys.exit(1)

    installed_ver = find_installed_compatible_python(versions_available)
    if installed_ver:
        print_section("解决方案：使用已安装的兼容 Python 版本")
        print_bold(f"检测到您的系统已安装 Python {installed_ver}，可直接使用。")
        install_instructions_for_version(installed_ver)
        sys.exit(0)

    source_build_python_instructions()
    sys.exit(1)

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

def handle_missing_rknn():
    if try_install_local_wheel():
        return
    print_warn("检测到缺少 rknn-toolkit-lite2")
    print_info(f"当前 Python 版本: {sys.version.split()[0]}")
    choice = input("是否自动从 GitHub 克隆仓库并尝试安装？[Y/n]: ").strip().lower()
    if choice in ('', 'y', 'yes'):
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

def check_packages():
    try:
        from rknnlite.api import RKNNLite
        print_ok("rknn-toolkit-lite2 已安装")
    except ImportError:
        handle_missing_rknn()

    numpy_ok = True
    opencv_ok = True
    try:
        import numpy as np
    except ImportError:
        numpy_ok = False
    try:
        import cv2
    except ImportError:
        opencv_ok = False

    if not numpy_ok or not opencv_ok:
        missing = []
        if not numpy_ok:
            missing.append("numpy")
        if not opencv_ok:
            missing.append("opencv-python")
        print_err(f"缺少依赖包: {', '.join(missing)}")

        if not is_venv():
            print_warn("当前不在虚拟环境中，请先激活 Python 3.10 虚拟环境。")
            print_bold("常用激活命令：")
            print_bold("  source /home/seeed/test_file_RK3588/rknpu_env_py310/bin/activate")
            print_bold("激活后重新运行本脚本，将自动安装缺失的包。")
            sys.exit(1)

        print_info(f"将安装: {' '.join(missing)}")
        choice = input("是否现在安装？[Y/n]: ").strip().lower()
        if choice in ('', 'y', 'yes'):
            print_bold("正在安装...")
            try:
                subprocess.run([sys.executable, '-m', 'pip', 'install'] + missing, check=True)
                print_ok("安装成功！请重新运行本脚本以继续测试。")
                sys.exit(0)
            except subprocess.CalledProcessError:
                print_err("安装失败，请手动执行：")
                print_bold(f"  pip install {' '.join(missing)}")
                sys.exit(1)
        else:
            print_bold(f"请手动执行: pip install {' '.join(missing)}")
            sys.exit(1)

    print_ok("opencv-python, numpy 已安装")

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

# ================= 测试函数 =================
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