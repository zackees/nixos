# geninclude from kitty.conf: turn on the GPU shader effects only when kitty
# renders on a GPU. Software GL (llvmpipe, e.g. LIBGL_ALWAYS_SOFTWARE=1 or a
# wedged NVIDIA driver) would run each effect as a full-window CPU pass every
# frame. Runs in kitty's embedded python at config load: stat calls only.
import glob  # io-ok: config-load only, see the gpu line
import os

software = (
    os.environ.get("LIBGL_ALWAYS_SOFTWARE") not in (None, "", "0")
    or os.environ.get("GALLIUM_DRIVER") in ("llvmpipe", "softpipe")
    or os.environ.get("KITTY_GPU_EFFECTS") == "off"
)
gpu = os.path.exists("/dev/nvidiactl") or bool(glob.glob("/dev/dri/renderD*"))  # io-ok: two stats, once at config load
if gpu and not software:
    print("custom_shaders gpu-effects")
    print("map ctrl+shift+f1 shader_event find-pointer")
