/// Bluetooth SIG "company identifiers" (curated subset).
///
/// A company ID in advertisement data names the company that REGISTERED the ID.
/// That is usually the chip, firmware or product maker, but it is not proof of
/// the product brand or model (for example, a speaker can carry a chip
/// vendor's ID).
///
/// To extend: add entries below, copied from the official Bluetooth SIG
/// "Company Identifiers" list (bluetooth.com/specifications/assigned-numbers).
/// Only add an entry when you have checked it against that list.
const Map<int, String> kCompanyIds = {
  0x0000: 'Ericsson Technology Licensing',
  0x0001: 'Nokia Mobile Phones',
  0x0002: 'Intel Corp.',
  0x0003: 'IBM Corp.',
  0x0004: 'Toshiba Corp.',
  0x0005: '3Com',
  0x0006: 'Microsoft',
  0x0007: 'Lucent',
  0x0008: 'Motorola',
  0x0009: 'Infineon Technologies AG',
  0x000A: 'Qualcomm (formerly CSR)',
  0x000B: 'Silicon Wave',
  0x000C: 'Digianswer A/S',
  0x000D: 'Texas Instruments Inc.',
  0x000F: 'Broadcom Corporation',
  0x001D: 'Qualcomm',
  0x0030: 'STMicroelectronics',
  0x0046: 'MediaTek, Inc.',
  0x004C: 'Apple, Inc.',
  0x0059: 'Nordic Semiconductor ASA',
  0x005D: 'Realtek Semiconductor',
  0x0075: 'Samsung Electronics Co. Ltd.',
  0x0078: 'Nike, Inc.',
  0x0087: 'Garmin International, Inc.',
  0x009E: 'Bose Corporation',
  0x00C4: 'LG Electronics',
  0x00E0: 'Google',
  0x012D: 'Sony Corporation',
  0x0131: 'Cypress Semiconductor',
  0x0157: 'Anhui Huami Information Technology (Amazfit/Zepp)',
  0x015D: 'Estimote, Inc.',
  0x0171: 'Amazon.com Services',
  0x01DA: 'Logitech International SA',
  0x027D: 'Huawei Technologies Co., Ltd.',
  0x02E5: 'Espressif Incorporated',
  0x038F: 'Xiaomi Inc.',
  0x0499: 'Ruuvi Innovations Ltd.',
};
