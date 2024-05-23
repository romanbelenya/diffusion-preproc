#! python

import numpy as np
import nibabel as nib
import argparse


def main(ap_basename: str, pa_basename: str) -> None:

    ap = nib.load(ap_basename + ".nii.gz")
    pa = nib.load(pa_basename + ".nii.gz")

    if np.array_equal(ap.affine, pa.affine):
        print("image affines are equal. not modifying ...")
        return

    pa.set_sform(ap.get_sform())
    pa.set_qform(pa.get_qform())

    nib.save(pa, pa_basename + ".nii.gz")


if __name__ == "__main__":

    parser = argparse.ArgumentParser()
    parser.add_argument("-a", "--ap_basename", help="Basename of the AP scan", type=str)
    parser.add_argument("-p", "--pa_basename", help="Basename of the PA scan", type=str)
    args = parser.parse_args()

    print(
        f"fixing the affine matrix of {args.pa_basename} to match {args.ap_basename} ..."
    )
    main(args.ap_basename, args.pa_basename)
