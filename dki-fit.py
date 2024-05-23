#! python

import argparse
from pathlib import Path

import numpy as np
import nibabel as nib
import dipy.reconst.dki as dki
from dipy.core.gradients import gradient_table, GradientTable


def main(data: np.ndarray, mask: np.ndarray, gtab: GradientTable) -> None:

    dkimodel = dki.DiffusionKurtosisModel(gtab)
    dkifit = dkimodel.fit(data, mask=mask)

    return dkifit


if __name__ == "__main__":

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-i", "--image", help="Preprocessed dwi data", type=str, required=True
    )
    parser.add_argument("-m", "--mask", help="Mask", type=str, required=True)
    parser.add_argument("-b", "--bvals", help="bvals", type=str, required=True)
    parser.add_argument("-v", "--bvecs", help="bvecs", type=str, required=True)
    parser.add_argument(
        "-o", "--output", help="Output directory", type=str, required=True
    )
    args = parser.parse_args()

    bvals = np.loadtxt(args.bvals)
    bvecs = np.loadtxt(args.bvecs)
    img = nib.load(args.image)
    mask = nib.load(args.mask)
    gtab = gradient_table(bvals, bvecs)

    assert img.shape[-1] == bvals.size == bvecs.shape[-1]

    dkifit = main(img.get_fdata(), mask.get_fdata(), gtab)

    outdir = Path(args.output)

    params = dkifit.model_params
    for i in range(3):
        eigenvalue = params[:, :, :, i]
        eigenvalue_img = nib.Nifti1Image(eigenvalue, affine=img.affine)
        eigenvalue_file = outdir / f"L{i+1}.nii.gz"
        nib.save(eigenvalue_img, eigenvalue_file)
        print(f">>> {eigenvalue_file}")

    for i, idcs in enumerate([(3, 6), (6, 9), (9, 12)]):
        start, end = idcs
        eigenvector = params[:, :, :, start:end]
        eigenvector_img = nib.Nifti1Image(eigenvector, affine=img.affine)
        eigenvector_file = outdir / f"V{i}.nii.gz"
        nib.save(eigenvector_img, eigenvector_file)
        print(f">>> {eigenvector_file}")

    for metric in ["kfa", "fa", "md", "ad", "rd", "model_S0"]:
        metric_file = outdir / (metric.upper() + ".nii.gz")
        arr = getattr(dkifit, metric)
        metric_img = nib.Nifti1Image(arr, affine=img.affine)
        nib.save(metric_img, metric_file)
        print(f">>> {metric_file}")
