#include <Python.h>
#define NPY_NO_DEPRECATED_API NPY_1_7_API_VERSION
#include <numpy/arrayobject.h>


// http://owa.as.wakwak.ne.jp/zope/docs/Python/BindingC/
// http://scipy-cookbook.readthedocs.io/items/C_Extensions_NumPy_arrays.html

static PyObject *NativeError;
typedef double real;


/* def create_hJc(qubo) */
static
PyObject *annealer_create_hJc(PyObject *self, PyObject *args) {
    PyArrayObject *objQubo = NULL;
    double *qubo;

    PyArrayObject *objH, *objJ;
    npy_long dims[2];
    double *h, *J, c;
    
    if (!PyArg_ParseTuple(args, "O!", &PyArray_Type, &objQubo))
         return NULL;
    if (objQubo == NULL)
        return NULL;
    /* ToDo: allow other types ? */
    if ((PyArray_DESCR(objQubo)->type_num != NPY_DOUBLE) || (PyArray_NDIM(objQubo) != 2))  {
        PyErr_SetString(PyExc_ValueError,
            "qubo is not double vector: array must be of type double and 2 dimensional (n).");
        return NULL;
    }
    qubo = (double*)PyArray_DATA(objQubo);
    int N = PyArray_SHAPE(objQubo)[0];
    int N1 = PyArray_SHAPE(objQubo)[1];
    if (N != N1) {
        PyErr_SetString(PyExc_ValueError,
            "qubo.shape[0] and qubo.shape[1] must be same.");
        return NULL;
    }

    dims[0] = N; dims[1] = N;
    objH = (PyArrayObject*)PyArray_ZEROS(1, dims, NPY_DOUBLE, 0);
    objJ = (PyArrayObject*)PyArray_ZEROS(2, dims, NPY_DOUBLE, 0);
    h = (double*)PyArray_DATA(objH);
    J = (double*)PyArray_DATA(objJ);
    c = 0.;
    
    /* initialize J */
    for (int j = 0; j < N; ++j)
        for (int i = 0; i < N; ++i)
            J[N * j + i] = 0.;
    
    real Jsum = 0.;
    real hsum = 0.;

    for (int j = 0; j < N; ++j) {
        real sum = 0.;
        for (int i = j + 1; i < N; ++i) {
            real r = qubo[j * N + i];
            sum += r;
            J[N * j + i] = r * 1.0/4.;
            J[N * i + j] = r * 1.0/4.;
            Jsum += r * 1.0 / 4.;
        }
        for (int i = 0; i < j; ++i)
            sum += qubo[N * j + i];
        
        real s = qubo[N * j + j];
        hsum += s * 1.0/2.;
        h[j] = s * 1.0 /2. + sum;
    }
    
    c = Jsum + hsum;
    
    /* h, J, c */
    return Py_BuildValue("OOd", objH, objJ, c);
}

/* def randomize_q(q) */
static
PyObject *annealer_randomize_q(PyObject *self, PyObject *args) {
    PyArrayObject *objQ = NULL;
    char *q;
    if (!PyArg_ParseTuple(args, "O!", &PyArray_Type, &objQ))
         return NULL;
    if (objQ == NULL)
        return NULL;
    if ((PyArray_DESCR(objQ)->type_num != NPY_INT8) || (PyArray_NDIM(objQ) != 2))  {
        PyErr_SetString(PyExc_ValueError,
            "q is not int8 vector: array must be of type int8 and 2 dimensional (n).");
        return NULL;
    }
    q = PyArray_BYTES(objQ);
    int m = PyArray_SHAPE(objQ)[0];
    int N = PyArray_SHAPE(objQ)[1];
    int stride = PyArray_STRIDE(objQ, 0);
    for (int j = 0; j < m; ++j) {
        char *qn = &q[stride * j];
        for (int i = 0; i < N; ++i)
            qn[i] = rand() < (RAND_MAX / 2) ? -1 : 1;
    }
    Py_INCREF(Py_None);
    return Py_None;

}
/* def anneal_one_step(q, G, kT, h, J, c) */
static
PyObject *annealer_anneal_one_step(PyObject *self, PyObject *args) {
    int N, m;
    if (!PyArg_ParseTuple(args, "ii", &N, &m))
        return NULL;
    return NULL;
}


static
PyMethodDef annealermethods[] = {
	{"create_hJc", annealer_create_hJc, METH_VARARGS},
	{"randomize_q", annealer_randomize_q, METH_VARARGS},
	{"anneal_one_step", annealer_anneal_one_step, METH_VARARGS},
	{NULL},
};




PyMODINIT_FUNC
initnative(void) {
    PyObject *m;

    m = Py_InitModule("native", annealermethods);
    import_array()
    if (m == NULL)
        return;

    NativeError = PyErr_NewException("native.error", NULL, NULL);
    Py_INCREF(NativeError);
    PyModule_AddObject(m, "error", NativeError);
}
