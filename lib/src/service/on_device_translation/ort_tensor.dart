// ignore_for_file: implementation_imports
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:onnxruntime_v2/src/bindings/onnxruntime_bindings_generated.dart' as bg;

/// Fast float tensor I/O on top of onnxruntime_v2.
///
/// The package's own helpers go through boxed Dart lists, which is far too slow
/// for a 1M-element detection map or a 40 x 18710 recognizer output, and they
/// turn a flat Float32List into a double tensor. These call the C API directly.

bg.OrtApi get _api => OrtEnv.instance.ortApiPtr.ref;

/// Creates a float32 tensor that owns a native copy of [data].
OrtValueTensor floatTensor(Float32List data, List<int> shape) {
  final ffi.Pointer<ffi.Float> dataPtr = calloc<ffi.Float>(data.length);
  dataPtr.asTypedList(data.length).setAll(0, data);
  final ffi.Pointer<ffi.Int64> shapePtr = calloc<ffi.Int64>(shape.length);
  for (int i = 0; i < shape.length; i++) {
    shapePtr[i] = shape[i];
  }
  final ffi.Pointer<ffi.Pointer<bg.OrtMemoryInfo>> memoryInfoPtr = calloc();
  final ffi.Pointer<ffi.Pointer<bg.OrtValue>> valuePtr = calloc();
  try {
    OrtStatus.checkOrtStatus(_api.CreateCpuMemoryInfo.asFunction<
        bg.OrtStatusPtr Function(int, int, ffi.Pointer<ffi.Pointer<bg.OrtMemoryInfo>>)>()(
      bg.OrtAllocatorType.OrtDeviceAllocator,
      bg.OrtMemType.OrtMemTypeDefault,
      memoryInfoPtr,
    ));
    OrtStatus.checkOrtStatus(_api.CreateTensorWithDataAsOrtValue.asFunction<
        bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtMemoryInfo>, ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Int64>, int, int,
            ffi.Pointer<ffi.Pointer<bg.OrtValue>>)>()(
      memoryInfoPtr.value,
      dataPtr.cast(),
      data.length * 4,
      shapePtr,
      shape.length,
      ONNXTensorElementDataType.float.value,
      valuePtr,
    ));
    _api.ReleaseMemoryInfo.asFunction<void Function(ffi.Pointer<bg.OrtMemoryInfo>)>()(memoryInfoPtr.value);
    // OrtValueTensor.release() frees dataPtr together with the tensor.
    return OrtValueTensor(valuePtr.value, dataPtr.cast());
  } catch (_) {
    calloc.free(dataPtr);
    rethrow;
  } finally {
    calloc.free(shapePtr);
    calloc.free(memoryInfoPtr);
    calloc.free(valuePtr);
  }
}

/// Shape of a tensor output.
List<int> tensorShape(OrtValue value) {
  final ffi.Pointer<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>> infoPtr = calloc();
  final ffi.Pointer<ffi.Size> countPtr = calloc();
  try {
    OrtStatus.checkOrtStatus(_api.GetTensorTypeAndShape.asFunction<
        bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>, ffi.Pointer<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>)>()(
      value.ptr,
      infoPtr,
    ));
    final ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> info = infoPtr.value;
    OrtStatus.checkOrtStatus(_api.GetDimensionsCount.asFunction<
        bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>, ffi.Pointer<ffi.Size>)>()(info, countPtr));
    final int count = countPtr.value;
    final ffi.Pointer<ffi.Int64> dims = calloc<ffi.Int64>(count);
    try {
      OrtStatus.checkOrtStatus(_api.GetDimensions.asFunction<
          bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>, ffi.Pointer<ffi.Int64>, int)>()(
        info,
        dims,
        count,
      ));
      return List<int>.generate(count, (i) => dims[i]);
    } finally {
      calloc.free(dims);
      _api.ReleaseTensorTypeAndShapeInfo.asFunction<void Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>)>()(info);
    }
  } finally {
    calloc.free(infoPtr);
    calloc.free(countPtr);
  }
}

/// Copies a float32 output tensor into Dart memory.
Float32List readFloatTensor(OrtValue value, int elementCount) {
  final ffi.Pointer<ffi.Pointer<ffi.Void>> dataPtr = calloc();
  try {
    OrtStatus.checkOrtStatus(_api.GetTensorMutableData.asFunction<
        bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>, ffi.Pointer<ffi.Pointer<ffi.Void>>)>()(value.ptr, dataPtr));
    return Float32List.fromList(dataPtr.value.cast<ffi.Float>().asTypedList(elementCount));
  } finally {
    calloc.free(dataPtr);
  }
}
