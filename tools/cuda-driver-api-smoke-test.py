#!/usr/bin/env python3
import ctypes


def get_symbol(cuda, name):
    try:
        return getattr(cuda, name)
    except AttributeError:
        return getattr(cuda, f"{name}_v2")


def check(name, rc):
    print(f"{name}={rc}", flush=True)
    if rc != 0:
        raise SystemExit(rc)


def main():
    cuda = ctypes.CDLL("libcuda.so.1")

    cu_init = cuda.cuInit
    cu_init.argtypes = [ctypes.c_uint]
    cu_init.restype = ctypes.c_int

    cu_device_get = cuda.cuDeviceGet
    cu_device_get.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_int]
    cu_device_get.restype = ctypes.c_int

    cu_ctx_create = get_symbol(cuda, "cuCtxCreate")
    cu_ctx_create.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_uint, ctypes.c_int]
    cu_ctx_create.restype = ctypes.c_int

    cu_ctx_destroy = get_symbol(cuda, "cuCtxDestroy")
    cu_ctx_destroy.argtypes = [ctypes.c_void_p]
    cu_ctx_destroy.restype = ctypes.c_int

    cu_ctx_synchronize = cuda.cuCtxSynchronize
    cu_ctx_synchronize.argtypes = []
    cu_ctx_synchronize.restype = ctypes.c_int

    cu_mem_alloc = get_symbol(cuda, "cuMemAlloc")
    cu_mem_alloc.argtypes = [ctypes.POINTER(ctypes.c_uint64), ctypes.c_size_t]
    cu_mem_alloc.restype = ctypes.c_int

    cu_mem_free = get_symbol(cuda, "cuMemFree")
    cu_mem_free.argtypes = [ctypes.c_uint64]
    cu_mem_free.restype = ctypes.c_int

    cu_memset_d8 = get_symbol(cuda, "cuMemsetD8")
    cu_memset_d8.argtypes = [ctypes.c_uint64, ctypes.c_ubyte, ctypes.c_size_t]
    cu_memset_d8.restype = ctypes.c_int

    cu_memcpy_dtoh = get_symbol(cuda, "cuMemcpyDtoH")
    cu_memcpy_dtoh.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_size_t]
    cu_memcpy_dtoh.restype = ctypes.c_int

    size = 4096
    pattern = 0x5A
    device = ctypes.c_int(-1)
    context = ctypes.c_void_p()
    device_ptr = ctypes.c_uint64(0)

    check("cuInit", cu_init(0))
    check("cuDeviceGet", cu_device_get(ctypes.byref(device), 0))
    print(f"device={device.value}", flush=True)
    check("cuCtxCreate", cu_ctx_create(ctypes.byref(context), 0, device.value))

    try:
        check("cuMemAlloc", cu_mem_alloc(ctypes.byref(device_ptr), size))
        try:
            check("cuMemsetD8", cu_memset_d8(device_ptr.value, pattern, size))
            check("cuCtxSynchronize", cu_ctx_synchronize())

            host_buffer = (ctypes.c_ubyte * size)()
            check("cuMemcpyDtoH", cu_memcpy_dtoh(host_buffer, device_ptr.value, size))

            mismatches = sum(1 for value in host_buffer if value != pattern)
            print(f"bytes_checked={size}", flush=True)
            print(f"mismatches={mismatches}", flush=True)
            if mismatches:
                raise SystemExit(98)
        finally:
            rc = cu_mem_free(device_ptr.value)
            print(f"cuMemFree={rc}", flush=True)
    finally:
        rc = cu_ctx_destroy(context)
        print(f"cuCtxDestroy={rc}", flush=True)

    print("cuda_smoke=pass", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
