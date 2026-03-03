import numpy as np
import tensorflow as tf

MODEL_PATH = "../weights/ecg_model.h5"
OUTPUT_DIR = "../weights/"

model = tf.keras.models.load_model(MODEL_PATH)

def quantize_and_save(array, filename):
    """Quantize to INT8 and save in RTL memory order"""
    scale = np.max(np.abs(array))
    if scale == 0:
        scale = 1
    w_q = np.clip(np.round(array / scale * 127), -128, 127).astype(np.int8)
    flat = w_q.flatten()
    with open(OUTPUT_DIR + filename, "w") as f:
        for val in flat:
            f.write(f"{int(val) & 0xFF:02X}\n")
    print(f"  {filename}: {len(flat)} values, scale={scale:.4f}")

for layer in model.layers:
    weights = layer.get_weights()
    if len(weights) != 2:
        continue
    w, b = weights

    if "conv1d" in layer.name and layer.filters == 8:
        # Keras: (5,1,8) → RTL needs [filter][channel][kernel] = (8,1,5)
        w_rtl = w.transpose(2, 1, 0)   # (5,1,8) → (8,1,5)
        quantize_and_save(w_rtl, "conv1_w.hex")
        quantize_and_save(b,     "conv1_b.hex")
        print(f"  Conv1 weight shape: {w.shape} → transposed to {w_rtl.shape}")

    elif "conv1d" in layer.name and layer.filters == 16:
        # Keras: (5,8,16) → RTL needs [filter][channel][kernel] = (16,8,5)
        w_rtl = w.transpose(2, 1, 0)   # (5,8,16) → (16,8,5)
        quantize_and_save(w_rtl, "conv2_w.hex")
        quantize_and_save(b,     "conv2_b.hex")
        print(f"  Conv2 weight shape: {w.shape} → transposed to {w_rtl.shape}")

    elif "dense" in layer.name and layer.units == 16:
        # Keras: (1152,16) → RTL needs [flat_idx][out_idx] = same order ✓
        quantize_and_save(w, "dense_w.hex")
        quantize_and_save(b, "dense_b.hex")
        print(f"  Dense1 weight shape: {w.shape} → no transpose needed")

    elif "dense" in layer.name and layer.units == 1:
        # Keras: (16,1) → RTL needs [in][out] = same order ✓
        quantize_and_save(w, "out_w.hex")
        quantize_and_save(b, "out_b.hex")
        print(f"  Out weight shape: {w.shape} → no transpose needed")

print("\nQuantization and HEX export complete.")
