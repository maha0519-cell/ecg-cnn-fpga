import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, models
from sklearn.model_selection import train_test_split

# Load data
X_norm = np.load("../test_data/X_norm.npy")
y_binary = np.load("../test_data/y_binary.npy")

# Train-test split
X_train, X_test, y_train, y_test = train_test_split(
    X_norm, y_binary, test_size=0.2, random_state=42
)

# Add channel dimension
X_train = X_train[..., None]
X_test = X_test[..., None]

# Define model
model = models.Sequential([
    layers.Conv1D(8, 5, activation='relu', input_shape=(300,1)),
    layers.MaxPooling1D(2),
    layers.Conv1D(16, 5, activation='relu'),
    layers.MaxPooling1D(2),
    layers.Flatten(),
    layers.Dense(16, activation='relu'),
    layers.Dense(1, activation='sigmoid')
])

model.compile(optimizer='adam',
              loss='binary_crossentropy',
              metrics=['accuracy'])

model.summary()

# Train
model.fit(X_train, y_train,
          epochs=10,
          batch_size=32,
          validation_data=(X_test, y_test))

# Save trained model
model.save("../weights/ecg_model.h5")

print("Training complete. Model saved.")