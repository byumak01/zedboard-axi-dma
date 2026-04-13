import os
import pandas as pd
import matplotlib.pyplot as plt

# Resolve paths relative to this script so it runs from anywhere
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "output")
DATA_FILE = os.path.join(OUTPUT_DIR, "usb_dma_hw_output_data.txt")
PLOT_FILE = os.path.join(OUTPUT_DIR, "dma.png")

# Read the CSV file
df = pd.read_csv(DATA_FILE, skipinitialspace=True)
plt.rcParams.update({'font.size': 8})

# Convert Q8.16 fixed-point to floating point
# Q8.16 means 8 integer bits and 16 fractional bits
# To convert: divide by 2^16 (65536)
def q8_16_to_float(value):
    # Handle signed values (if the 24th bit is set, it's negative)
    if value >= 2**23:  # Check if negative in Q8.16 (sign bit)
        value = value - 2**24
    return value / 65536.0

# Columns that need Q8.16 conversion (all except 'step' and spike columns which are likely binary)
q8_16_columns = ['pre_in1', 'pre_in2', 'post_in', 'w1', 'w2', 'c1', 'c2']

for col in q8_16_columns:
    if col in df.columns:
        df[col] = df[col].apply(q8_16_to_float)

# Create a figure with 6 subplots (2 rows, 3 columns)
fig, axes = plt.subplots(2, 3, figsize=(14, 8))
#fig.suptitle('Neural Spike Data Visualization', fontsize=14)

# Plot 1: w1 and w2
axes[0, 0].plot(df['step'], df['w1'], label='w1', marker='o')
axes[0, 0].plot(df['step'], df['w2'], label='w2', marker='s')
axes[0, 0].set_xlabel('Zaman (ms)')
axes[0, 0].set_ylabel('Ağırlık')
axes[0, 0].set_title('Ağırlıklar (w1, w2)')
axes[0, 0].legend()
axes[0, 0].grid(True, alpha=0.3)

# Plot 2: c1 and c2
axes[0, 1].plot(df['step'], df['c1'], label='c1', marker='o')
axes[0, 1].plot(df['step'], df['c2'], label='c2', marker='s')
axes[0, 1].set_xlabel('Zaman (ms)')
axes[0, 1].set_ylabel('Kalsiyum Miktarı')
axes[0, 1].set_title('Kalsiyum (c1, c2)')
axes[0, 1].legend()
axes[0, 1].grid(True, alpha=0.3)

# Plot 3: pre_in1 and pre_in2
axes[0, 2].plot(df['step'], df['pre_in1'], label='pre_in1', marker='o')
axes[0, 2].plot(df['step'], df['pre_in2'], label='pre_in2', marker='s')
axes[0, 2].set_xlabel('Zaman (ms)')
axes[0, 2].set_ylabel('Akım')
axes[0, 2].set_title('Pre-sinaptik Nöronlara Uygulanan Akımlar')
axes[0, 2].legend()
axes[0, 2].grid(True, alpha=0.3)

# Calculate spike counts
pre1_spike_count = df['pre1_spike'].sum()
pre2_spike_count = df['pre2_spike'].sum()
post_spike_count = df['post_spike'].sum()

# Plot 4: pre1_spike
axes[1, 0].plot(df['step'], df['pre1_spike'], label='pre1_spike', marker='o', color='green')
axes[1, 0].set_xlabel('Zaman (ms)')
axes[1, 0].set_ylabel('Vuru')
axes[1, 0].set_title(f'1. Pre-sinaptik Nöron')
axes[1, 0].legend()
axes[1, 0].grid(True, alpha=0.3)

# Plot 5: pre2_spike
axes[1, 1].plot(df['step'], df['pre2_spike'], label='pre2_spike', marker='o', color='orange')
axes[1, 1].set_xlabel('Zaman (ms)')
axes[1, 1].set_ylabel('Vuru')
axes[1, 1].set_title(f'2. Pre-sinaptik Nöron')
axes[1, 1].legend()
axes[1, 1].grid(True, alpha=0.3)

# Plot 6: post_spike
axes[1, 2].plot(df['step'], df['post_spike'], label='post_spike', marker='o', color='red')
axes[1, 2].set_xlabel('Zaman (ms)')
axes[1, 2].set_ylabel('Vuru')
axes[1, 2].set_title(f'Post-sinaptik Nöron ')
axes[1, 2].legend()
axes[1, 2].grid(True, alpha=0.3)

# Adjust layout to prevent overlap
plt.tight_layout()

# Save the figure
plt.subplots_adjust(hspace=0.2, wspace=0.15, left=0.035, right=0.997, top=0.965, bottom=0.055)
plt.savefig(PLOT_FILE, dpi=150, bbox_inches='tight')
plt.show()

print(f"Plot saved as '{PLOT_FILE}'")
